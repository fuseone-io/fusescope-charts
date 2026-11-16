#!/usr/bin/env bash
# The investigation's replicas belong to on-call between upgrades: in a throwaway kind cluster, a
# release scaled to one by the scale subresource upgrades without a field conflict and stays at
# one; scaled back to zero, it upgrades at zero; a new release installs at zero. Needs kind,
# kubectl and a Helm that upgrades by server-side apply (Helm 4).
#
#   scripts/fusescope-parity-scale-check.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
chart=$here/../charts/fusescope-parity
values=$chart/ci/staging-values.yaml
cluster=fsp-scale-check-$$
context=kind-$cluster
work=$(mktemp -d)
trap 'kind delete cluster --name "$cluster" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

kind create cluster --name "$cluster" --kubeconfig "$work/kubeconfig" --wait 120s >/dev/null
export KUBECONFIG=$work/kubeconfig
kubectl --context "$context" create namespace parity >/dev/null
kubectl --context "$context" create namespace parity-run-keys >/dev/null

replicas() {
    kubectl --context "$context" -n parity get statefulset "$1-investigate" -o jsonpath='{.spec.replicas}'
}
scale() {
    kubectl --context "$context" -n parity patch statefulset "$1-investigate" --subresource=scale --type=merge -p "{\"spec\":{\"replicas\":$2}}" >/dev/null
}
release() {
    helm --kube-context "$context" upgrade --install "$1" "$chart" -n parity -f "$values" --set "marginSeconds=$2" >/dev/null
}
expect() {
    [ "$(replicas "$1")" = "$2" ] || { echo "FAIL: $3: $1-investigate has $(replicas "$1") replicas, not $2" >&2; exit 1; }
    echo "ok    $3"
}

release check 300
expect check 0 "a new release installs at zero"
scale check 1
release check 301 || { echo "FAIL: the upgrade conflicts with on-call's scale" >&2; exit 1; }
expect check 1 "an upgrade keeps on-call's one replica"
scale check 0
release check 302
expect check 0 "an upgrade after on-call scaled back keeps zero"
release other 300
expect other 0 "another new release installs at zero"
