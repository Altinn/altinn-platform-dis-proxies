#!/usr/bin/env python3
"""Check the rendered output of every overlay against the invariants in CLAUDE.md.

Rendering is the baseline and it is not sufficient on its own: every invariant
below renders perfectly, applies cleanly, and then misbehaves in the cluster.
That is what this script is for -- it is the cheap check against rendered output
that CLAUDE.md asks for, run in CI before anything is published.

Usage:
    .github/scripts/check-invariants.py                  # every overlay
    .github/scripts/check-invariants.py dis-to-legacy/envs/at22

Needs kubectl on PATH, and either PyYAML or yq for parsing.
"""

import glob
import json
import os
import subprocess
import sys
from collections import defaultdict

# Ports that a Linkerd Server may cover. The health port is deliberately absent:
# creating a Server for a port removes Linkerd's automatic kubelet probe
# allowance, so a Server on the probe port means pods run but never go Ready.
SERVER_PORTS = {"http"}

# Kubernetes object names are limited to 63 characters. namePrefix plus a
# generated ConfigMap hash gets closer to that than you would expect.
MAX_NAME = 63


def render(overlay):
    """kustomize build, as CLAUDE.md prescribes it."""
    return subprocess.run(
        ["kubectl", "kustomize", overlay],
        capture_output=True, text=True, check=True,
    ).stdout


def parse(text):
    """Parse a multi-document YAML stream, via PyYAML or yq, whichever is here."""
    try:
        import yaml
        return [d for d in yaml.safe_load_all(text) if d]
    except ImportError:
        pass
    out = subprocess.run(
        ["yq", "ea", "-o=json", "[.]", "-"],
        input=text, capture_output=True, text=True, check=True,
    ).stdout
    return [d for d in json.loads(out) if d]


def check(overlay, docs):
    """Return a list of failures for one rendered overlay."""
    fail = []
    present = defaultdict(set)
    for d in docs:
        present[d["kind"]].add(d["metadata"]["name"])

    def missing(kind, name):
        return name not in present[kind]

    for d in docs:
        kind = d["kind"]
        name = d["metadata"]["name"]
        spec = d.get("spec", {})

        # Invariant 4: kustomizeconfig.yaml teaches kustomize about the Linkerd
        # CRDs. Without it namePrefix renames a Server or MeshTLSAuthentication
        # and leaves the AuthorizationPolicy pointing at the old name. Renders
        # perfectly, then fails closed -- 403 on everything. Broken twice
        # already, and it scales with the number of services.
        if kind == "AuthorizationPolicy":
            target = spec["targetRef"]
            if missing(target["kind"], target["name"]):
                fail.append(
                    f"AuthorizationPolicy/{name}: targetRef "
                    f"{target['kind']}/{target['name']} is not in this render "
                    f"(namePrefix did not reach the reference)"
                )
            for ref in spec.get("requiredAuthenticationRefs", []):
                if missing(ref["kind"], ref["name"]):
                    fail.append(
                        f"AuthorizationPolicy/{name}: requiredAuthenticationRef "
                        f"{ref['kind']}/{ref['name']} is not in this render "
                        f"(namePrefix did not reach the reference)"
                    )

        if kind == "HTTPRoute":
            for parent in spec.get("parentRefs", []):
                # Invariant 1: same namespace makes this a producer route, which
                # applies to callers anywhere. A namespace here makes it a
                # consumer route, scoped to callers in the route's own namespace
                # -- the legacy callers stop matching and hit the endpoint-less
                # anchor instead. Presents as a broken anchor, not a misplaced
                # route.
                if parent.get("namespace"):
                    fail.append(
                        f"HTTPRoute/{name}: parentRef carries "
                        f"namespace={parent['namespace']}, making this a consumer "
                        f"route scoped to that namespace's callers"
                    )
                # Invariant 3: the anchor must keep the legacy name exactly, so
                # namePrefix is scoped to the nested proxy/ kustomization. If it
                # leaked upwards the anchor renders as <service>-<service> and
                # this parentRef resolves to nothing.
                if missing("Service", parent["name"]):
                    fail.append(
                        f"HTTPRoute/{name}: anchor Service/{parent['name']} is "
                        f"not in this render (namePrefix leaked onto the anchor?)"
                    )

            for rule in spec.get("rules", []):
                for backend in rule.get("backendRefs", []):
                    # Invariant 2: a backendRef may cross namespaces and the new
                    # leg must, because the migrated app lives in its own
                    # namespace. Nothing here creates that Service, so a
                    # cross-namespace backend cannot be checked from the render
                    # -- only same-namespace ones are.
                    if backend.get("namespace"):
                        continue
                    if missing("Service", backend["name"]):
                        fail.append(
                            f"HTTPRoute/{name}: backendRef Service/"
                            f"{backend['name']} is not in this render"
                        )

        # Invariant 5: probes stay on their own port, which has no Server and so
        # keeps Linkerd's automatic probe allowance.
        if kind == "Server" and spec.get("port") not in SERVER_PORTS:
            fail.append(
                f"Server/{name}: covers port {spec.get('port')!r}; a Server on "
                f"the probe port removes the kubelet probe allowance and pods "
                f"never go Ready"
            )

        # Invariant 6: a config missing an entire server block is still valid
        # syntax. nginx -t passes, the health port keeps the pod Ready, and
        # Linkerd returns 502 for everything because nothing accepts on 8080.
        if kind == "ConfigMap" and "nginx.conf" in d.get("data", {}):
            listeners = d["data"]["nginx.conf"].count("\n    listen ")
            if listeners < 2:
                fail.append(
                    f"ConfigMap/{name}: nginx.conf declares {listeners} listener(s), "
                    f"expected 2 (health and traffic)"
                )

        if len(name) > MAX_NAME:
            fail.append(f"{kind}/{name}: name is {len(name)} characters, limit is {MAX_NAME}")

    return fail


def main():
    overlays = sys.argv[1:]
    if not overlays:
        overlays = sorted(
            os.path.dirname(p)
            for p in glob.glob("dis-to-legacy/envs/*/kustomization.yaml")
        )
        overlays.append("dis-to-legacy/platform/dummy")

    failed = False
    for overlay in overlays:
        try:
            docs = parse(render(overlay))
        except subprocess.CalledProcessError as e:
            print(f"{overlay}: RENDER FAILED\n{e.stderr}")
            failed = True
            continue

        problems = check(overlay, docs)
        counts = defaultdict(int)
        for d in docs:
            counts[d["kind"]] += 1
        summary = (
            f"routes={counts['HTTPRoute']} "
            f"policies={counts['AuthorizationPolicy']} "
            f"servers={counts['Server']}"
        )
        print(f"{overlay:<34} {summary:<40} {'OK' if not problems else 'FAIL'}")
        for p in problems:
            print(f"    {p}")
        failed = failed or bool(problems)

    if failed:
        print("\nSee 'Invariants that fail silently' in CLAUDE.md.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
