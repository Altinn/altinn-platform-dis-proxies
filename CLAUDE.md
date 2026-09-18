# Legacy-proxy shim — working notes

A temporary shim that lets services migrate from the legacy cluster into this one
without callers changing anything. Each migrated service gets an nginx pod that
forwards to the legacy cluster, fronted by an anchor Service carrying the legacy
name, with a Linkerd `HTTPRoute` splitting traffic by weight between the legacy
cluster and the migrated app.

Team, service and environment names below are placeholders (`<team>`, `<service>`,
`<env>`) — the real ones change. The namespace is set in exactly one place, the
`envs/<env>/kustomization.yaml`; read it there rather than hardcoding it anywhere
new. The namespace itself is created out of band, not by this repo.

**Deployment is not settled.** It is moving to GitHub pipelines plus GitOps, and
the shape of that is undecided. Do not assume a delivery mechanism, invent
pipeline files, or design around one. Everything here is plain kustomize that
renders standalone, and it should stay that way.

## Project structure & module organization

```
dis-to-legacy/
├── platform/          # identical everywhere; platform team owns it
│   ├── base/          #   the reusable proxy unit — app- and env-agnostic
│   ├── dummy/         #   canary backend, in its OWN namespace
│   └── client/        #   Component: meshed pod to test from
├── teams/             # identical in every environment; each team owns its folder
│   └── <team>/
│       └── <service>/
│           ├── anchor.yaml              # Service carrying the legacy name
│           ├── httproute.yaml           # the split; backends and their namespaces
│           └── proxy/
│               ├── kustomization.yaml   # namePrefix + proxy-for label
│               ├── allowed-clients.yaml # who may call this service
│               └── allowed-paths.conf   # which base paths may be proxied
└── envs/              # THE ONLY LAYER THAT DIFFERS BETWEEN CLUSTERS
    └── <env>/
        ├── kustomization.yaml   # which teams are present; no weights here
        └── <team>/              # that team's weights for this env — the review unit
```

An **environment overlay is the deployable unit**: `dis-to-legacy/envs/<env>` is what
gets applied. `platform/dummy/` is separate and renders on its own — it is a
stand-in for a migrated app, not part of any overlay.

One nginx pod per service, one config for all of them: `base/` is app-agnostic
because the legacy ingress routes on path prefix and nothing is rewritten. Per-app
isolation comes from `namePrefix` plus a `dis.altinn.no/proxy-for` label.

## Verifying a change

Rendering is the baseline, and it is not sufficient on its own — every failure in
the next section renders perfectly:

```sh
kubectl kustomize dis-to-legacy/envs/<env>
kubectl kustomize dis-to-legacy/platform/dummy
```

Beyond that, check the invariants below against the rendered output. A rendered
manifest that looks right can still be wrong in ways only a running cluster shows.

## Invariants that fail silently

These render cleanly, apply cleanly, and then misbehave. Each has a cheap check
against rendered output where one exists.

1. **A route's `parentRef` must be in the anchor's namespace.** Same namespace
   makes it a *producer route*, which applies to callers in any namespace. A
   different namespace makes it a *consumer route*, scoped to callers in the
   route's own namespace — the legacy callers would stop matching and hit the
   zero-endpoint anchor instead. Presents as a broken anchor, not a misplaced
   route. This is why `anchor.yaml` and `httproute.yaml` live together.
2. **A `backendRef` may cross namespaces, and must.** The migrated app lives in
   its own namespace, so the new leg always carries `namespace:`. Nothing here
   creates that Service — the app team does, on their own schedule. Pointing
   non-zero weight at a backend that does not exist yet fails.
3. **`namePrefix` must not reach the anchor.** Its name has to stay exactly the
   legacy name, so the prefix is scoped to the nested `proxy/` kustomization. Move
   it up a level and the anchor renders as `<service>-<service>`.
4. **`base/kustomizeconfig.yaml` teaches kustomize about Linkerd CRDs.** Without
   it, labels never reach `Server.podSelector`, and `namePrefix` renames a `Server`
   or `MeshTLSAuthentication` while leaving the `AuthorizationPolicy` reference
   behind. Both render perfectly and **fail closed** — 403 on everything.
   *Check:* every `AuthorizationPolicy`'s `targetRef.name` and
   `requiredAuthenticationRefs[].name` must match a resource present in the same
   render. This has broken twice; the second time only once a second service
   existed, so it scales with adoption.
5. **Probes stay on their own port.** Creating a `Server` for a port removes
   Linkerd's automatic kubelet probe allowance for it. Health is on a separate port
   with no `Server`, so probes keep working. Collapse them onto one port and pods
   run but never go Ready.
6. **`nginx.conf` must declare both listeners.** A config missing an entire
   `server` block is still valid syntax — `nginx -t` passes, the health port keeps
   the pod Ready, and Linkerd returns 502 for every request because nothing
   accepts on the traffic port. *Check:* both `listen` lines present in the
   rendered ConfigMap.
7. **The upstream ConfigMap is external and not hash-suffixed.** It is created
   outside this repo and holds the legacy ingress host. Changing it does not roll
   pods; they keep the old value until restarted.
8. **Deny-by-default inbound policy shows up as HTTP 403, not a connection
   error**, and is invisible from pod health because probes are auto-authorized.
   Target-side authorization in the migrated app's namespace is the app team's
   job, and the identity presented there is the *original caller's* — the new leg
   never passes through nginx.

## Editing conventions

- Nothing per-service belongs in `platform/`. Adding a service touches only a
  `teams/<team>/` folder plus one line and a weight patch in each `envs/<env>/`.
- `teams/` must render identically for every environment. If something differs
  per cluster, it belongs in `envs/<env>/`.
- Weights live only in `envs/<env>/<team>/`, never in `teams/`, so review can be
  scoped per team. The `httproute.yaml` in `teams/` carries the safe default —
  all traffic to the legacy cluster.
- **Beware text-based edits to `nginx.conf`.** `location / {` appears in both
  server blocks; an anchored replacement matched the wrong one and deleted a whole
  server block. Match on surrounding context and re-read the file afterwards.

## Security & configuration

- **No internal hostnames in this repo.** The legacy ingress host is supplied out
  of band and lives only in a cluster ConfigMap.
  `platform/base/upstream.conf.example` documents the shape with placeholder
  values and is not applied. Keep it that way — these files are meant to be
  publishable.
- Each service declares which base paths may be proxied. Without that the shim is
  a general-purpose door into the legacy cluster for anyone authorized to call it.
- Client allow-lists are per service, prefixed so two services cannot collide in
  the shared anchor namespace.
