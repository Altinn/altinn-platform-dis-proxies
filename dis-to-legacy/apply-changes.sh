#!/usr/bin/env bash
#
# Apply the kubewrapper-proxy POC to dis-core-at23-aks / test-proxy-vga.
#
# Guardrails: this script never mutates your kubeconfig. It pins --context and
# --namespace on every kubectl call, and refuses to run unless the cluster
# behind that context is provably the one the pin file was taken from.
#
# Usage:
#   ./apply-changes.sh pin      # one-time: record the target cluster's identity
#   ./apply-changes.sh upstream HOST   # one-time: point this cluster at its
#                                      # legacy ingress (kept out of the repo)
#   ./apply-changes.sh diff     # (default) show what would change
#   ./apply-changes.sh apply    # apply and wait for the rollout
#   ./apply-changes.sh dummy    # deploy the canary, in its own namespace
#   ./apply-changes.sh status   # show the deployed resources
#
# Order on a fresh cluster: pin -> upstream -> dummy -> apply. 'apply' refuses to
# point traffic at a cross-namespace backend that does not exist yet.
#   ./apply-changes.sh weights P D   # live-shift the split, proxy vs dummy
#   ./apply-changes.sh sample [N]    # send N requests and tally the backends
#   ./apply-changes.sh shell    # exec into the meshed client pod
#   ./apply-changes.sh delete   # remove everything this script created

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

readonly CONTEXT="dis-core-at23-aks"
# Derived from the rendered manifests, not hardcoded -- KUSTOMIZE_DIR can point
# at any team folder, and each renders into its own namespace. detect_namespace
# sets this before anything touches the cluster.
NAMESPACE=""
# Every team folder must render into this one namespace -- that is what keeps
# bare in-cluster service names working. The value is still DERIVED from the
# manifests, and then checked against this, so a typo in one team's
# kustomization fails loudly instead of creating a stray namespace.
readonly SHARED_NAMESPACE="test-proxy-vga"
# The overlay to deploy. Layering lives under manifests/:
#   platform/base    reusable proxy unit, app-agnostic
#   platform/dummy   synthetic canary component
#   platform/client  test client component
#   teams/<team>/    one folder per migrated service
#   envs/<env>/      the deployable unit: upstream host + weights
#
# Override to render another environment: KUSTOMIZE_DIR=manifests/envs/at22 ...
readonly KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-manifests/envs/at23}"
readonly PIN_FILE=".cluster-pin"
readonly SERVICE_NAME="kuberneteswrapper-kubernetes-api-wrapper"
readonly ROUTE_NAME="kuberneteswrapper-kubernetes-api-wrapper"
readonly ROUTE_KIND="httproutes.policy.linkerd.io"
readonly POC_LABEL="app.kubernetes.io/part-of=dis-core-at23-proxy-poc"
readonly UPSTREAM_CM="legacy-upstream"
# The canary backend. Deployed on its own, never as part of an environment, so
# that a service's route file shows its real backends without anything being
# patched in behind your back.
readonly DUMMY_DIR="manifests/platform/dummy"
readonly DUMMY_SVC="kubewrapper-dummy"
# The canary lives in its OWN namespace, not alongside the anchors -- a real
# migrated app always does, so the canary models that and the routes' cross-
# namespace backendRef becomes a genuine test.
readonly DUMMY_NAMESPACE="test-proxy-vga-app"

# Every kind this POC is allowed to create. Anything else in the rendered
# output is treated as an accident and aborts the run.
readonly ALLOWED_KINDS="AuthorizationPolicy ConfigMap Deployment HTTPRoute \
MeshTLSAuthentication Namespace Server Service ServiceAccount"
readonly CLIENT_SA="poc-client"
# The path the upstream actually serves. The legacy ingress routes on path
# prefix, so this must reach the far end untouched.
readonly PROBE_PATH="/kuberneteswrapper/api/v1/deployments"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

kc() { kubectl --context "$CONTEXT" "$@"; }

# ---------------------------------------------------------------------------
# Guardrail 1: the context must exist and must point at the cluster we pinned.
#
# The context *name* alone is not proof of anything -- a kubeconfig entry can be
# repointed at a different cluster while keeping its name. So we also compare
# the API server URL and the UID of the kube-system namespace, which is unique
# per cluster and cannot be forged by editing kubeconfig.
# ---------------------------------------------------------------------------
probe_cluster() {
  local cluster server uid
  cluster=$(kubectl config view -o "jsonpath={.contexts[?(@.name=='${CONTEXT}')].context.cluster}")
  [[ -n "$cluster" ]] || die "context '${CONTEXT}' not found in your kubeconfig."

  server=$(kubectl config view -o "jsonpath={.clusters[?(@.name=='${cluster}')].cluster.server}")
  [[ -n "$server" ]] || die "no server URL for cluster '${cluster}'."

  uid=$(kc get namespace kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null) \
    || die "cannot reach cluster via context '${CONTEXT}'. Are you logged in?"
  [[ -n "$uid" ]] || die "could not read the kube-system namespace UID."

  PROBED_SERVER="$server"
  PROBED_UID="$uid"
}

require_pinned_cluster() {
  [[ -f "$PIN_FILE" ]] || die "no ${PIN_FILE} found. Run './apply-changes.sh pin' first."

  # shellcheck disable=SC1090
  source "$PIN_FILE"
  [[ -n "${PINNED_SERVER:-}" && -n "${PINNED_UID:-}" ]] \
    || die "${PIN_FILE} is malformed. Delete it and re-run 'pin'."

  probe_cluster

  if [[ "$PROBED_SERVER" != "$PINNED_SERVER" ]]; then
    die "refusing to continue: context '${CONTEXT}' now points at a different API server.
       pinned:  ${PINNED_SERVER}
       current: ${PROBED_SERVER}
     If this change is expected, re-run './apply-changes.sh pin'."
  fi

  if [[ "$PROBED_UID" != "$PINNED_UID" ]]; then
    die "refusing to continue: the cluster behind '${CONTEXT}' is not the pinned cluster.
       pinned kube-system UID:  ${PINNED_UID}
       current kube-system UID: ${PROBED_UID}
     If this change is expected, re-run './apply-changes.sh pin'."
  fi

  info "target verified: context=${CONTEXT} namespace=${NAMESPACE}"
  info "                 server=${PROBED_SERVER}"
}

# ---------------------------------------------------------------------------
# Work out which namespace this overlay deploys into, and insist there is
# exactly one. Every kubectl call is then pinned to it, so a manifest that
# quietly moved namespace cannot be applied somewhere unintended.
# ---------------------------------------------------------------------------
detect_namespace() {
  local found
  found=$(kubectl kustomize "$KUSTOMIZE_DIR" 2>/dev/null \
    | awk '/^  namespace:/ {print $2}' | sort -u) \
    || die "failed to render ${KUSTOMIZE_DIR}/."

  [[ -n "$found" ]] || die "no namespace found in ${KUSTOMIZE_DIR}/. Does the overlay set one?"

  if [[ $(wc -l <<<"$found") -gt 1 ]]; then
    die "${KUSTOMIZE_DIR}/ spans more than one namespace: ${found//$'\n'/, }"
  fi

  if [[ "$found" != "$SHARED_NAMESPACE" ]]; then
    die "${KUSTOMIZE_DIR}/ renders into namespace '${found}', expected '${SHARED_NAMESPACE}'.
     Every team folder shares one namespace so that callers can keep using bare
     service names. Check the 'namespace:' field in ${KUSTOMIZE_DIR}/kustomization.yaml."
  fi

  NAMESPACE="$found"
}

# ---------------------------------------------------------------------------
# Guardrail 2: the rendered manifests must stay inside this POC's blast radius.
#
# Every namespaced object must declare namespace test-proxy-vga (kubectl also
# enforces this because we pass -n, but failing here gives a clearer message),
# only the allowlisted kinds may appear, and the Service must keep the legacy
# name that callers depend on.
# ---------------------------------------------------------------------------
verify_manifests() {
  local rendered kind bad_namespaces
  rendered=$(kubectl kustomize "$KUSTOMIZE_DIR") || die "failed to render ${KUSTOMIZE_DIR}/."

  while read -r kind; do
    [[ -n "$kind" ]] || continue
    if [[ " ${ALLOWED_KINDS} " != *" ${kind} "* ]]; then
      die "rendered output contains disallowed kind '${kind}'. Allowed: ${ALLOWED_KINDS}."
    fi
  done < <(printf '%s\n' "$rendered" | grep '^kind:' | awk '{print $2}' | sort -u)

  bad_namespaces=$(printf '%s\n' "$rendered" \
    | awk '/^  namespace:/ {print $2}' | sort -u | grep -v "^${NAMESPACE}$" || true)
  if [[ -n "$bad_namespaces" ]]; then
    die "rendered output spans more than one namespace: ${NAMESPACE}, ${bad_namespaces//$'\n'/, }
     This POC keeps every resource for a service in one namespace, so this is
     almost certainly a mistake in ${KUSTOMIZE_DIR}."
  fi

  printf '%s\n' "$rendered" | grep -q "name: ${SERVICE_NAME}$" \
    || die "rendered output does not contain the expected Service '${SERVICE_NAME}'."

  verify_policy_refs "$rendered"
  verify_listeners "$rendered"

  info "manifests verified: $(printf '%s\n' "$rendered" | grep -c '^kind:') resources, namespace ${NAMESPACE} only"
}

# The legacy ingress this cluster forwards to. Deliberately not in this repo --
# it is read back from the ConfigMap so that diagnostics can name it without a
# hostname ever being committed.
upstream_host() {
  kc -n "$NAMESPACE" get configmap "$UPSTREAM_CM" \
    -o jsonpath='{.data.upstream\.conf}' 2>/dev/null \
    | sed -n 's|^proxy_pass https\{0,1\}://\([^;]*\);.*|\1|p' | head -1
}

# ---------------------------------------------------------------------------
# Guardrail 4: the externally-provisioned upstream ConfigMap must exist.
#
# The proxy mounts it by fixed name. If it is missing the pods never leave
# ContainerCreating, with the reason buried in describe output -- so fail here
# with something actionable instead.
# ---------------------------------------------------------------------------
verify_upstream_configmap() {
  kc get namespace "$NAMESPACE" >/dev/null 2>&1 || return 0   # first apply

  kc -n "$NAMESPACE" get configmap "$UPSTREAM_CM" >/dev/null 2>&1 || die \
    "ConfigMap '${UPSTREAM_CM}' is missing from namespace '${NAMESPACE}'.
     It names the legacy ingress for this cluster and is kept out of this repo
     on purpose, so nothing here has to stay private. Create it with:
       ./apply-changes.sh upstream <legacy-ingress-host>
     Shape: manifests/platform/base/upstream.conf.example"

  local host; host=$(upstream_host)
  [[ -n "$host" ]] || warn "${UPSTREAM_CM} exists but no proxy_pass host could be read from it."
  info "upstream: ${host:-unknown} (from ConfigMap ${UPSTREAM_CM})"
}

# ---------------------------------------------------------------------------
# Run a throwaway pod to completion and echo its logs on stdout.
#
# Deliberately NOT 'kubectl run --attach'. With a meshed pod the main container
# does not exist yet while linkerd-init and linkerd-proxy are still coming up,
# so --attach loses the race, warns, and silently falls back to streaming logs.
# Create, poll for a terminal phase, then read the logs by explicit container
# name -- which also avoids the "Defaulted container" noise.
#
# Everything informational goes to stderr so callers can capture stdout.
# ---------------------------------------------------------------------------
run_oneshot_pod() {
  local name="$1" image="$2" inject="$3" timeout="$4" script="$5" sa="${6:-}"

  # The sampler has to run under the authorized ServiceAccount, otherwise
  # Linkerd's deny-by-default inbound policy rejects it with 403.
  local -a extra=()
  [[ -n "$sa" ]] && extra=(--overrides="{\"spec\":{\"serviceAccountName\":\"${sa}\"}}")

  # shellcheck disable=SC2064
  trap "kc -n '$NAMESPACE' delete pod '$name' --ignore-not-found --wait=false >/dev/null 2>&1 || true" RETURN

  kc -n "$NAMESPACE" run "$name" \
    --restart=Never --image="$image" \
    --annotations="linkerd.io/inject=${inject}" \
    "${extra[@]+"${extra[@]}"}" \
    --command -- sh -c "$script" >&2 \
    || { warn "could not create pod ${name}"; return 1; }

  local phase="" deadline=$(( SECONDS + timeout ))
  while :; do
    phase=$(kc -n "$NAMESPACE" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case "$phase" in
      Succeeded|Failed) break ;;
    esac
    if (( SECONDS >= deadline )); then
      warn "pod ${name} did not finish within ${timeout}s (phase=${phase:-unknown})"
      break
    fi
    sleep 2
  done

  kc -n "$NAMESPACE" logs "$name" -c "$name" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Guardrail 6: cross-namespace backends must exist before traffic can reach them.
#
# The migrated app lives in its own namespace, so the "new" leg of every split is
# a cross-namespace backendRef. Nothing in this repo creates that Service -- the
# app team does, in their namespace, on their own schedule.
#
# A missing backend at weight 0 is the normal pre-migration state, so warn. A
# missing backend with weight > 0 means traffic is being pointed at something
# that is not there, so refuse: that is the failure this whole model introduces.
#
# Needs the cluster, so it runs from cmd_apply rather than verify_manifests.
# ---------------------------------------------------------------------------
verify_cross_namespace_backends() {
  local rendered problems="" pending=""
  rendered=$(kubectl kustomize "$KUSTOMIZE_DIR") || return 0

  while read -r ns name weight; do
    [[ -n "$ns" ]] || continue
    if kc -n "$ns" get service "$name" >/dev/null 2>&1; then
      continue
    fi
    if (( weight > 0 )); then
      problems+="       ${ns}/${name} (weight ${weight})"$'\n'
    else
      pending+="       ${ns}/${name} (weight 0)"$'\n'
    fi
  done < <(printf '%s\n' "$rendered" | awk '
      /^ +- name: / { n=$3; ns=""; w="" ; next }
      /^ +namespace: / && n != "" { ns=$2; next }
      /^ +weight: / && n != "" { if (ns != "") print ns, n, $2; n=""; next }
    ')

  if [[ -n "$pending" ]]; then
    warn "cross-namespace backends not deployed yet (fine at weight 0):"
    printf '%s' "$pending" >&2
    warn "the app team creates these in their own namespace."
  fi

  if [[ -n "$problems" ]]; then
    local hint=""
    grep -q "${DUMMY_NAMESPACE}/${DUMMY_SVC}" <<<"$problems" \
      && hint="
     For the canary specifically: ./apply-changes.sh dummy"
    die "these backends carry traffic but do not exist:
$(printf '%s' "$problems")
     Requests routed to a missing backend fail. Either deploy them, or set their
     weight back to 0 in the environment overlay before applying.${hint}"
  fi
}

# ---------------------------------------------------------------------------
# Guardrail 5: the proxy config must actually listen on the port the Service
# targets.
#
# An nginx config missing a whole server block is still VALID -- 'nginx -t'
# passes, the pod starts, and the readiness probe on the health port succeeds,
# so the Deployment reports Ready. The only symptom is that Linkerd returns 502
# for every request because nothing accepts the connection, which looks like an
# upstream failure rather than a missing listener.
#
# Cheap to check and invisible otherwise, so check it.
# ---------------------------------------------------------------------------
verify_listeners() {
  local rendered="$1" port missing=""
  for port in 8080 8081; do
    grep -q "listen  *${port};" <<<"$rendered" || missing+=" ${port}"
  done
  [[ -z "$missing" ]] || die "the proxy nginx config has no listener on:${missing}
     8080 is the port the Service targets; 8081 serves the readiness probe.
     A config missing a server block still passes 'nginx -t' and still reports
     Ready, so this would only show up as 502 on every request.
     Check manifests/platform/base/nginx.conf."
}

# ---------------------------------------------------------------------------
# Guardrail 3: every AuthorizationPolicy reference must resolve.
#
# An AuthorizationPolicy points at a Server and a MeshTLSAuthentication by name.
# namePrefix renames those, and kustomize only follows the rename because of the
# nameReference rules in platform/base/kustomizeconfig.yaml. Drop those rules and
# the manifests still render perfectly while every policy points at nothing --
# which fails closed, so the only symptom is 403 on every request.
#
# Cheap to check, and it is exactly the bug that is invisible in a diff.
# ---------------------------------------------------------------------------
verify_policy_refs() {
  local broken
  broken=$(printf '%s\n' "$1" | python3 -c "
import sys, re
docs = sys.stdin.read().split('\n---\n')
def names(kind):
    return {re.search(r'^  name: (\S+)', d, re.M).group(1)
            for d in docs if re.search(r'^kind: ' + kind + r'$', d, re.M)}
servers, auths = names('Server'), names('MeshTLSAuthentication')
for d in docs:
    if not re.search(r'^kind: AuthorizationPolicy$', d, re.M):
        continue
    n = re.search(r'^  name: (\S+)', d, re.M).group(1)
    t = re.search(r'targetRef:\n(?:.*\n)*?\s+name: (\S+)', d)
    a = re.search(r'requiredAuthenticationRefs:\n(?:.*\n)*?\s+name: (\S+)', d)
    if t and t.group(1) not in servers:
        print(f'{n} -> Server/{t.group(1)}')
    if a and a.group(1) not in auths:
        print(f'{n} -> MeshTLSAuthentication/{a.group(1)}')
") || return 0

  if [[ -n "$broken" ]]; then
    die "AuthorizationPolicy references do not resolve:
$(sed 's/^/       /' <<<"$broken")
     These render fine but fail closed -- every caller would get 403.
     Check the nameReference rules in manifests/platform/base/kustomizeconfig.yaml."
  fi
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
cmd_pin() {
  probe_cluster
  cat > "$PIN_FILE" <<EOF
# Identity of the cluster this POC may be applied to.
# Regenerate with './apply-changes.sh pin' after an intentional cluster change.
PINNED_SERVER="${PROBED_SERVER}"
PINNED_UID="${PROBED_UID}"
EOF
  info "pinned '${CONTEXT}' to ${PROBED_SERVER} (kube-system UID ${PROBED_UID})"
  info "wrote ${PIN_FILE}"
}

# Create or update the ConfigMap naming this cluster's legacy ingress.
#
# The host is passed on the command line and never written to the repo. The
# directives themselves are generic, so they live here rather than in a file.
cmd_upstream() {
  local host="${1:-}"
  [[ -n "$host" ]] || die "usage: ./apply-changes.sh upstream <legacy-ingress-host>"
  [[ "$host" =~ ^[a-zA-Z0-9.-]+$ ]] || die "'${host}' does not look like a hostname."

  require_pinned_cluster

  kc get namespace "$NAMESPACE" >/dev/null 2>&1 \
    || { info "creating namespace ${NAMESPACE}"; kc create namespace "$NAMESPACE"; }

  local conf
  conf=$(cat <<EOS
# Generated by apply-changes.sh. One per cluster, shared by every proxy pod.
proxy_pass https://${host};
proxy_set_header Host ${host};
proxy_ssl_server_name         on;
proxy_ssl_name                ${host};
proxy_ssl_verify              on;
proxy_ssl_verify_depth        3;
proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
proxy_ssl_protocols           TLSv1.2 TLSv1.3;
EOS
)

  kc -n "$NAMESPACE" create configmap "$UPSTREAM_CM" \
    --from-literal=upstream.conf="$conf" \
    --dry-run=client -o yaml | kc -n "$NAMESPACE" apply -f -

  info "${UPSTREAM_CM} now points at ${host}"
  warn "this ConfigMap is NOT hash-suffixed, so running proxy pods keep the old"
  warn "value until restarted. After changing the host, roll them:"
  warn "  kubectl --context ${CONTEXT} -n ${NAMESPACE} rollout restart deployment -l ${POC_LABEL}"
}

# Deploy the canary backend, and nothing else.
#
# Separate from 'apply' on purpose. The canary is POC scaffolding standing in for
# a team's real new-cluster Service; keeping it out of the environment overlays
# means a team folder reads as the reference it is meant to be.
cmd_dummy() {
  require_pinned_cluster

  # Its own namespace, created here -- the manifests declare it, so no -n is
  # needed and the kustomization stays the single source of truth.
  info "applying ${DUMMY_DIR}/ into ${DUMMY_NAMESPACE}"
  kc apply -k "$DUMMY_DIR"
  kc -n "$DUMMY_NAMESPACE" rollout status "deployment/${DUMMY_SVC}" --timeout=120s

  info "${DUMMY_SVC} is up in ${DUMMY_NAMESPACE}"
  info "the routes in ${NAMESPACE} reach it by a cross-namespace backendRef;"
  info "shift weight onto it with './apply-changes.sh weights <proxy> <dummy>'"
}

cmd_diff() {
  require_pinned_cluster
  verify_manifests
  info "diff against the live cluster:"
  # kubectl diff exits 1 when there are differences; that is not an error here.
  kc -n "$NAMESPACE" diff -k "$KUSTOMIZE_DIR" || true
}

cmd_apply() {
  require_pinned_cluster
  verify_upstream_configmap
  verify_cross_namespace_backends
  verify_manifests
  info "applying ${KUSTOMIZE_DIR}/"
  kc -n "$NAMESPACE" apply -k "$KUSTOMIZE_DIR"
  if grep -q "name: ${DUMMY_SVC}$" <<<"$(kubectl kustomize "$KUSTOMIZE_DIR")" \
     && ! kc -n "$DUMMY_NAMESPACE" get service "$DUMMY_SVC" >/dev/null 2>&1; then
    warn "routes here reference '${DUMMY_SVC}' in ${DUMMY_NAMESPACE}, which is not deployed."
    warn "Harmless while its weight is 0, but shifting traffic onto it will fail."
    warn "Deploy it with: ./apply-changes.sh dummy"
  fi

  info "waiting for rollout"
  # Readiness here IS the probe test: if a Server ever covers a probe port
  # without a matching probe authorization, pods run but never go Ready.
  # Derived, not hardcoded: adding a service to a team folder must not require
  # editing this script.
  local d
  for d in $(kubectl kustomize "$KUSTOMIZE_DIR" \
               | awk '/^kind: Deployment$/{f=1} f&&/^  name: /{print $2; f=0}'); do
    if ! kc -n "$NAMESPACE" rollout status "deployment/${d}" --timeout=180s; then
      echo
      warn "rollout of ${d} did not complete."
      warn "If its pods are Running but never Ready, suspect probe authorization:"
      warn "creating a Server for a port removes Linkerd's automatic probe"
      warn "allowance for that port. This POC keeps probes on a separate port"
      warn "(8081) that no Server covers -- check that still holds:"
      warn "  ${KUSTOMIZE_DIR}/authorization.yaml  (Servers use port: http)"
      warn "  ${KUSTOMIZE_DIR}/*-deployment.yaml   (probes use port: health)"
      echo
      kc -n "$NAMESPACE" get pods -l "$POC_LABEL" 2>/dev/null | sed 's/^/      /'
      return 1
    fi
  done
  cmd_status
}

cmd_status() {
  kc -n "$NAMESPACE" get deployment,pod,service,configmap -l "$POC_LABEL"
  echo
  info "migration targets in ${DUMMY_NAMESPACE}:"
  kc -n "$DUMMY_NAMESPACE" get deployment,pod,service -l "$POC_LABEL" 2>/dev/null \
    || warn "  nothing there yet -- './apply-changes.sh dummy'"
  echo
  info "current split:"
  kc -n "$NAMESPACE" get "$ROUTE_KIND" "$ROUTE_NAME" \
    -o jsonpath='{range .spec.rules[0].backendRefs[*]}  {.name}{"\t"}weight {.weight}{"\n"}{end}' \
    2>/dev/null || warn "could not read ${ROUTE_KIND}/${ROUTE_NAME}"
}

# Live-shift the weights without a full re-apply. Handy while testing; note
# that the next 'apply' resets them to what httproute.yaml says.
cmd_weights() {
  local proxy_weight="${1:-}" dummy_weight="${2:-}"
  [[ "$proxy_weight" =~ ^[0-9]+$ && "$dummy_weight" =~ ^[0-9]+$ ]] \
    || die "usage: ./apply-changes.sh weights <proxy-weight> <dummy-weight>  (non-negative integers)"
  (( proxy_weight + dummy_weight > 0 )) || die "at least one weight must be greater than zero."

  require_pinned_cluster
  kc -n "$NAMESPACE" patch "$ROUTE_KIND" "$ROUTE_NAME" --type=json -p "$(cat <<JSON
[
  {"op": "replace", "path": "/spec/rules/0/backendRefs/0/weight", "value": ${proxy_weight}},
  {"op": "replace", "path": "/spec/rules/0/backendRefs/1/weight", "value": ${dummy_weight}}
]
JSON
)"
  warn "this is a live override; './apply-changes.sh apply' will reset it to httproute.yaml"
  cmd_status
}

# Send N requests through a throwaway MESHED pod and tally which backend
# answered. The pod must be meshed -- Linkerd applies outbound policy in the
# client's proxy, so an unmeshed client sees no split at all (and, with the
# anchor Service having no endpoints, simply fails).
#
# Failures are reported by kind rather than lumped together as "error":
#   connect-error  the request never got an HTTP response (DNS, no endpoints,
#                  refused, timeout) -- this is what a non-working split gives
#   http-5xx/4xx   a backend answered, but unhappily
#   dummy          the in-cluster greeting backend served it
#   legacy-proxy   the nginx proxy to the legacy cluster served it
cmd_sample() {
  local count="${1:-100}"
  [[ "$count" =~ ^[0-9]+$ ]] || die "usage: ./apply-changes.sh sample [request-count]"
  (( count > 0 )) || die "request count must be greater than zero."

  require_pinned_cluster

  local script result
  script=$(cat <<EOS
for i in \$(seq 1 ${count}); do
  code=\$(curl -s -o /tmp/body -w '%{http_code}' --max-time 10 "http://${SERVICE_NAME}${PROBE_PATH}" 2>/dev/null) \
    || { echo connect-error; continue; }

  # Identify the backend from the body first, then qualify it with the status.
  # The dummy self-identifies even in its 404, so a mis-routed request is still
  # traceable to a backend instead of collapsing into a bare status code.
  if grep -q kubewrapper-dummy /tmp/body 2>/dev/null; then
    backend=dummy
  elif [ "\$code" = "403" ]; then
    # Linkerd's own denial: no backend body at all.
    backend=policy-denied
  else
    backend=legacy-proxy
  fi

  if [ "\$code" = "200" ]; then
    echo "\$backend"
  else
    echo "\$backend-http-\$code"
  fi
done | sort | uniq -c
EOS
)

  info "sending ${count} requests to ${SERVICE_NAME}${PROBE_PATH} from a meshed pod"
  result=$(run_oneshot_pod "poc-sampler-$$" "curlimages/curl:8.11.1" enabled \
    $(( count / 2 + 90 )) "$script" "$CLIENT_SA") || die "could not run the sampler pod."

  echo
  printf '%s\n' "$result"
  echo

  # Order matters. A 'legacy-proxy-http-502' IS an HTTP response -- it means the
  # split routed correctly and nginx failed on its own egress leg. Testing for a
  # successful backend first would misfile it as "nothing got through" and send
  # you looking at the route instead of the upstream.
  if grep -qE 'legacy-proxy-http-5' <<<"$result"; then
    show_upstream_hint
  elif ! grep -qE '(dummy|legacy-proxy)$' <<<"$result"; then
    show_split_diagnostics "$result"
  fi
}

# 5xx from the legacy-proxy backend means nginx could not complete the request
# upstream. That is the proxy's own egress leg, nothing to do with the split.
show_upstream_hint() {
  echo
  warn "the legacy-proxy backend returned 5xx: the split routed correctly and"
  warn "nginx failed on its own leg out to the legacy cluster."
  echo

  info "upstream configured in ConfigMap ${UPSTREAM_CM}:"
  local host; host=$(upstream_host)
  printf '      %s\n' "${host:-<none -- could not read proxy_pass from the ConfigMap>}"
  echo

  # The error log names the cause exactly, so fetch it rather than describing
  # how to fetch it. nginx logs the upstream failure reason verbatim.
  info "nginx error log from the proxy pods:"
  local logs
  logs=$(kc -n "$NAMESPACE" logs -l "dis.altinn.no/proxy-for=${SERVICE_NAME}" \
           -c nginx --tail=200 --prefix 2>/dev/null \
         | grep -iE 'error|upstream|SSL|resolv|refused|timed out' | tail -15)
  if [[ -n "$logs" ]]; then
    printf '%s\n' "$logs" | sed 's/^/      /'
  else
    warn "      no error lines found. Widen the window with:"
    warn "      kubectl --context ${CONTEXT} -n ${NAMESPACE} logs \\"
    warn "        -l dis.altinn.no/proxy-for=${SERVICE_NAME} -c nginx --tail=200"
  fi
  echo

  info "what the usual lines mean:"
  info "  'SSL certificate verify error'   upstream cert not trusted, or chain incomplete"
  info "  'host not found in certificate'  SAN does not cover the configured host"
  info "  'no resolver defined' / NXDOMAIN the host does not resolve from the pods"
  info "  'Connection refused' / 'timed out' unreachable, or a stale resolved address"
  info "                                   (nginx resolves once at startup -- restart the pods)"
  echo
  info "compare against a direct call from the client pod, which uses the system"
  info "trust store and does not go through the proxy:"
  info "  ./apply-changes.sh shell"
  info "  curl -v https://${host:-<upstream-host>}${PROBE_PATH}"
}

# Printed when no request reached a backend. Branches on WHY, because a 403
# (policy) and a connect-error (routing) need completely different fixes.
show_split_diagnostics() {
  local result="$1"

  if grep -q '403' <<<"$result"; then
    warn "403 means the split routed correctly and the far end refused you."
    warn "This cluster runs Linkerd deny-by-default inbound policy."
    echo
    info "Servers covering the backends:"
    kc -n "$NAMESPACE" get servers.policy.linkerd.io -l "$POC_LABEL" 2>/dev/null | sed 's/^/      /'
    echo
    info "AuthorizationPolicies and the identities they trust:"
    kc -n "$NAMESPACE" get authorizationpolicies.policy.linkerd.io -l "$POC_LABEL" 2>/dev/null | sed 's/^/      /'
    kc -n "$NAMESPACE" get meshtlsauthentications.policy.linkerd.io -l "$POC_LABEL" \
      -o jsonpath='{range .items[*]}      {.metadata.name}: {.spec.identities}{"\n"}{end}' 2>/dev/null
    echo
    info "The caller must present one of those identities. The sampler runs as"
    info "ServiceAccount '${CLIENT_SA}', i.e."
    info "  ${CLIENT_SA}.${NAMESPACE}.serviceaccount.identity.linkerd.cluster.local"
    echo
    warn "If that identity is not in the list above, add it to authorization.yaml."
    warn "Check the receiving proxy's own account of the denial with:"
    warn "  kubectl --context ${CONTEXT} -n ${DUMMY_NAMESPACE} logs -l app.kubernetes.io/name=kubewrapper-dummy -c linkerd-proxy"
    return
  fi

  warn "no request got an HTTP response at all. Working through the causes:"
  echo

  info "1. Has Linkerd accepted the HTTPRoute? (Accepted=True, ResolvedRefs=True)"
  kc -n "$NAMESPACE" get "$ROUTE_KIND" "$ROUTE_NAME" -o jsonpath=\
'{range .status.parents[*]}      parent: {.parentRef.kind}/{.parentRef.name}{"\n"}{range .conditions[*]}        {.type}={.status} ({.reason}) {.message}{"\n"}{end}{end}' 2>/dev/null \
    || warn "      could not read ${ROUTE_KIND}/${ROUTE_NAME} status"
  echo

  info "2. Are the backends up?"
  kc -n "$NAMESPACE" get pods -l "$POC_LABEL" \
    -o custom-columns=POD:.metadata.name,READY:.status.containerStatuses[*].ready,PHASE:.status.phase 2>/dev/null \
    | sed 's/^/      /'
  echo

  info "3. Backend EndpointSlices (both should list addresses):"
  kc -n "$NAMESPACE" get endpointslices \
    -l 'kubernetes.io/service-name=kubewrapper-proxy' 2>/dev/null \
    | sed 's/^/      /'
  kc -n "$DUMMY_NAMESPACE" get endpointslices \
    -l 'kubernetes.io/service-name=kubewrapper-dummy' 2>/dev/null \
    | sed 's/^/      /'
  echo

  info "4. Anchor EndpointSlices (EMPTY by design):"
  kc -n "$NAMESPACE" get endpointslices \
    -l "kubernetes.io/service-name=${SERVICE_NAME}" 2>/dev/null \
    | sed 's/^/      /'
  echo

  warn "A zero-endpoint anchor has already been shown to work as a route parent"
  warn "in this cluster, so suspect DNS or the backends before the anchor."
}

# Drop into the meshed client pod. Calls made from here go through a Linkerd
# proxy, which is what makes the HTTPRoute split apply.
cmd_shell() {
  require_pinned_cluster
  info "exec into poc-client; try:"
  printf '      curl -s http://%s/foo/bar\n' "$SERVICE_NAME"
  printf '      dig +short %s\n\n' "$(upstream_host)"
  kc -n "$NAMESPACE" exec -it deploy/poc-client -c netshoot -- bash
}

cmd_delete() {
  require_pinned_cluster
  verify_manifests
  warn "deleting the POC resources in ${NAMESPACE} (the namespace itself is kept)"
  # Deliberately not 'delete -k': that would delete the Namespace too, taking
  # anything else in test-proxy-vga with it. Delete by label instead.
  kc -n "$NAMESPACE" delete deployment,service,configmap,serviceaccount \
    -l "$POC_LABEL" --ignore-not-found
  # Separate call: the CRD may not exist, which must not fail the whole delete.
  if kc api-resources --api-group=policy.linkerd.io 2>/dev/null | grep -q httproutes; then
    kc -n "$NAMESPACE" delete "$ROUTE_KIND" -l "$POC_LABEL" --ignore-not-found
    kc -n "$NAMESPACE" delete authorizationpolicies.policy.linkerd.io,\
meshtlsauthentications.policy.linkerd.io,servers.policy.linkerd.io \
      -l "$POC_LABEL" --ignore-not-found
  else
    warn "policy.linkerd.io HTTPRoute CRD not present; skipping route deletion"
  fi

  # The canary lives in its own namespace and is deployed separately, so it has
  # to be deleted separately too. The namespace itself is kept.
  if kc get namespace "$DUMMY_NAMESPACE" >/dev/null 2>&1; then
    warn "deleting the canary in ${DUMMY_NAMESPACE} (the namespace itself is kept)"
    kc -n "$DUMMY_NAMESPACE" delete deployment,service,configmap,serviceaccount \
      -l "$POC_LABEL" --ignore-not-found
    if kc api-resources --api-group=policy.linkerd.io 2>/dev/null | grep -q servers; then
      kc -n "$DUMMY_NAMESPACE" delete authorizationpolicies.policy.linkerd.io,\
meshtlsauthentications.policy.linkerd.io,servers.policy.linkerd.io \
        -l "$POC_LABEL" --ignore-not-found
    fi
  fi
}

main() {
  command -v kubectl >/dev/null || die "kubectl not found on PATH."

  # 'pin' only records cluster identity, so it does not need the manifests.
  [[ "${1:-diff}" == "pin" ]] || detect_namespace

  case "${1:-diff}" in
    pin)    cmd_pin ;;
    upstream) shift; cmd_upstream "$@" ;;
    dummy)  cmd_dummy ;;
    diff)   cmd_diff ;;
    apply)  cmd_apply ;;
    status)  require_pinned_cluster; cmd_status ;;
    weights) shift; cmd_weights "$@" ;;
    sample)  shift; cmd_sample "$@" ;;
    shell)   cmd_shell ;;
    delete)  cmd_delete ;;
    *)      die "unknown command '$1'. Use: pin | upstream | diff | dummy | apply | status | weights | sample | shell | delete" ;;
  esac
}

main "$@"
