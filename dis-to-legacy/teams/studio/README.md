# studio — moving services out of the legacy cluster

One folder per service that used to live in the legacy cluster. Callers keep
using the same address they always have; what changes is where the traffic
behind that address ends up.

Today every service here sends **all** of its traffic to the legacy cluster.
Moving to your new one is two small edits, and you can go as slowly as you like.

## 1. Point at your new service

Once your service is deployed and running in this cluster, open
`altinn-storage/httproute.yaml`. Near the bottom there is a commented-out block —
uncomment it and fill in the namespace your service runs in:

```yaml
- name: altinn-storage
  namespace: your-namespace-here
  port: 80
  weight: 0
```

`weight: 0` means it receives nothing yet. That is on purpose: this step only
says *where* your service is, it does not send anything to it.

Do this only after your service is actually deployed. Naming something that
does not exist yet breaks the route for everyone.

## 2. Give it a weight

Weights are not in this folder — they live per environment, in
`envs/<env>/studio/kustomization.yaml`. That way you change one environment at
a time, and only your team's services are in the file.

You will find a block per service with a second, commented-out entry. Uncomment
it and set the number.

## What the weights do

The two numbers are the legacy cluster first, your new service second. They are
**relative**, not percentages — what matters is their ratio.

| legacy | new | what happens |
|--------|-----|--------------|
| 100 | 0 | everything still goes to the legacy cluster (where we are now) |
| 90 | 10 | roughly one request in ten reaches your new service |
| 50 | 50 | an even split |
| 0 | 100 | everything reaches your new service; legacy is idle |

Requests are split one by one, so both versions are live at the same time. Take
it in steps — 10, then 50, then 100 — and watch your service between each one.

**Rolling back is the same edit in reverse.** Put the numbers back and traffic
returns to the legacy cluster. Nothing is torn down while the legacy side still
has weight, so there is always something to fall back to.

Change one environment at a time. Each environment has its own file, so at22
moving to 50/50 has no effect on prod.

## Allowing callers in

This cluster **denies by default**. Nothing can call anything unless it has been
named on a list. That is different from the legacy cluster, where any workload
could reach any other, and it is the thing most likely to trip you up.

There are two lists, covering two different legs:

1. **Reaching your service through the shim** — `<service>/proxy/allowed-clients.yaml`,
   in this folder. This is the leg that carries traffic while the weight is
   still on the legacy cluster.
2. **Reaching your new service directly** — on your own side, in your service's
   own namespace. Not in this repo, and not something this folder can do for
   you. This is the leg that carries traffic once you give the new backend a
   weight in step 2.

**Both need the same callers.** Filling in the first and forgetting the second
means everything works fine at 100/0 and starts failing the moment you shift any
weight across.

### What a caller looks like

A caller is named by its service account:

```
<service-account>.<namespace>.serviceaccount.identity.linkerd.cluster.local
```

so for example:

```yaml
identities:
  - "altinn-events.default.serviceaccount.identity.linkerd.cluster.local"
```

A whole namespace at once, if you need it:

```yaml
  - "*.default.serviceaccount.identity.linkerd.cluster.local"
```

It is the **calling** workload's service account, not yours.

### Right now, nobody is allowed

Every `allowed-clients.yaml` in this folder currently holds a placeholder that
matches no real workload, so every caller is refused. That is deliberate — an
empty list is safer than a guessed one. Replace it with your real callers before
anyone needs to reach you.

### How it fails

You get **HTTP 403**, immediately. Not a timeout, not a connection error — the
request arrives and is turned away.

Your pods stay healthy and Ready throughout, because health checks are allowed
automatically and never go near these lists. So a service can look completely
fine and still be refusing every request. If 403s appear right after a change,
this list is the first place to look.

### One trap worth knowing

A caller's identity includes **the namespace it runs in**. While a caller still
lives in the shared namespace it is `<service-account>.default....`. The day
that caller migrates into its own namespace, its identity changes and it quietly
drops off your list — it was never removed, it just is not called that any more.

If a caller that used to work suddenly gets 403s and nothing on your side
changed, check whether it moved.

If something looks wrong after a change, set the weight back first and work out
why afterwards.

## A note on altinn-muescheli

There is deliberately no folder for `altinn-muescheli`. It has no route on the
legacy cluster's ingress, so nothing reaches it from the outside and there is
nothing for a proxy here to stand in front of. It was on the original list of
services to migrate; it was dropped once that turned out to be the case.

If that changes and it does get an ingress route, it needs a folder like the
others and a line in `kustomization.yaml` — copy a sibling.
