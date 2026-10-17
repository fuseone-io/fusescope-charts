#!/usr/bin/env bash
# Deploys the FuseScope lab: Keycloak, FuseScope (+PostgreSQL, ClickHouse), k8s-infra and
# the OpenTelemetry Demo. Idempotent; secrets are generated once and kept in the cluster.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
charts="$(cd "$here/../../charts" && pwd)"
ns="${FUSESCOPE_LAB_NAMESPACE:-fusescope-lab}"
demo_ns="${FUSESCOPE_LAB_DEMO_NAMESPACE:-otel-demo}"

kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$demo_ns" --dry-run=client -o yaml | kubectl apply -f -

secret_value() { # secret key
  kubectl -n "$ns" get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d || true
}

ensure_secret() { # secret key
  if [ -z "$(secret_value "$1" "$2")" ]; then
    kubectl -n "$ns" create secret generic "$1" --from-literal="$2=$(openssl rand -hex 24)" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi
}

ensure_secret fusescope-lab-oidc client-secret
ensure_secret fusescope-lab-oidc-users password
ensure_secret fusescope-lab-keycloak admin-password

export FUSESCOPE_LAB_OIDC_CLIENT_SECRET="$(secret_value fusescope-lab-oidc client-secret)"
export FUSESCOPE_LAB_USER_PASSWORD="$(secret_value fusescope-lab-oidc-users password)"
envsubst '${FUSESCOPE_LAB_OIDC_CLIENT_SECRET} ${FUSESCOPE_LAB_USER_PASSWORD}' \
  < "$here/keycloak-realm.json.tmpl" \
  | kubectl -n "$ns" create secret generic fusescope-lab-keycloak-realm --from-file=fusescope-realm.json=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$ns" apply -f "$here/keycloak.yaml"
kubectl -n "$ns" rollout restart deployment/keycloak >/dev/null 2>&1 || true

helm dependency build "$charts/fusescope" >/dev/null
helm upgrade --install fusescope "$charts/fusescope" -n "$ns" -f "$here/values-fusescope.yaml" --wait --timeout 15m
helm upgrade --install k8s-infra "$charts/k8s-infra" -n "$ns" -f "$here/values-k8s-infra.yaml" --wait --timeout 10m

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update open-telemetry >/dev/null
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo --version 0.42.4 -n "$demo_ns" \
  -f "$here/values-otel-demo.yaml" --wait --timeout 15m

echo
echo "FuseScope:  https://fusescope.fuseone.io"
echo "Keycloak:   https://sso.fuseone.io (admin password: kubectl -n $ns get secret fusescope-lab-keycloak -o jsonpath='{.data.admin-password}' | base64 -d)"
echo "SSO users:  admin@ / editor@ / viewer@lab.fuseone.io (password: kubectl -n $ns get secret fusescope-lab-oidc-users -o jsonpath='{.data.password}' | base64 -d)"
echo "OTel Demo:  https://otel-demo.fuseone.io"
