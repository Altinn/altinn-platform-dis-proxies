# altinn-platform-dis-proxies

Configuration of the proxies use while migrating to DIS

## Published artifact

Every push to `main` publishes `dis-to-legacy/` as a Flux OCI artifact:

```
altinncr.azurecr.io/dis/legacy-proxies
```

with two tags — the short commit sha, which is immutable and what you roll back
to, and `main`, which moves and is what the clusters reconcile.

**One artifact holds the whole tree**, not one per environment. The overlays
reference `../../../teams/` and `../../../../platform/base`, so an artifact
containing only `envs/<env>/` would have nothing to build against. Each cluster
picks its own overlay with `path`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: legacy-proxies
spec:
  interval: 5m
  url: oci://altinncr.azurecr.io/dis/legacy-proxies
  ref:
    tag: main
  provider: azure
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: legacy-proxies
spec:
  interval: 10m
  sourceRef:
    kind: OCIRepository
    name: legacy-proxies
  # The only line that differs between clusters.
  path: ./envs/at22
  prune: true
```

To pin a cluster to a known-good revision, set `ref.tag` to a commit sha instead
of `main`.

Two things the artifact does not carry, both created out of band:

- the namespace
- a ConfigMap named `legacy-upstream`, holding the legacy ingress host for that
  cluster — see `dis-to-legacy/platform/base/upstream.conf.example`

## Checks

`.github/scripts/check-invariants.py` renders every overlay and checks the
rendered output against the invariants in CLAUDE.md — the ones that render
cleanly, apply cleanly, and then misbehave. CI runs it before publishing, and it
runs locally the same way:

```sh
./.github/scripts/check-invariants.py
./.github/scripts/check-invariants.py dis-to-legacy/envs/at22   # one overlay
```
