# FuseScope lab

A reproducible FuseScope environment on a Kubernetes cluster with an NGINX ingress class
and cert-manager (`letsencrypt-prod`), as used on the FuseOne lab (`*.fuseone.io`).

| Component | Release / namespace | URL |
|---|---|---|
| FuseScope (backend, UI, collector, ClickHouse, PostgreSQL) | `fusescope` / `fusescope-lab` | https://fusescope.fuseone.io |
| OTLP/HTTP ingestion | collector ingress | https://otlp.fusescope.fuseone.io |
| Keycloak (OIDC identity provider, realm `fusescope`) | manifest / `fusescope-lab` | https://sso.fuseone.io |
| k8s-infra (cluster metrics, events, logs) | `k8s-infra` / `fusescope-lab` | — |
| OpenTelemetry Demo (traces, metrics, logs) | `otel-demo` / `otel-demo` | https://otel-demo.fuseone.io |

## Deploy

```bash
KUBECONFIG=/path/to/kubeconfig ./deploy.sh
```

The script is idempotent. On the first run it generates the OIDC client secret, the
Keycloak admin password and the password of the lab SSO users, keeps them in secrets of
the `fusescope-lab` namespace and renders the Keycloak realm from
`keycloak-realm.json.tmpl`. No secret is stored in this repository.

## Single sign-on

SSO is declared in the FuseScope configuration file (`signoz.config` in
`values-fusescope.yaml`), so the `lab.fuseone.io` domain shows up read-only in
*Settings → Single Sign-on*. Keycloak groups map to FuseScope roles:

| Keycloak user | Group | FuseScope role |
|---|---|---|
| `admin@lab.fuseone.io` | `fusescope-admins` | Admin |
| `editor@lab.fuseone.io` | `fusescope-editors` | Editor |
| `viewer@lab.fuseone.io` | `fusescope-viewers` | Viewer |

```bash
kubectl -n fusescope-lab get secret fusescope-lab-oidc-users -o jsonpath='{.data.password}' | base64 -d
```

Create the first FuseScope admin through the sign-up page with an address outside
`lab.fuseone.io`; the SSO domain is applied to the organization within a minute.

## Remove

```bash
helm -n otel-demo uninstall otel-demo
helm -n fusescope-lab uninstall k8s-infra fusescope
kubectl delete namespace otel-demo fusescope-lab
```
