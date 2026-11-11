# FuseScope parity

> **Staging only.** The parity (D5) compares the trace views of the Go
> backend on ClickHouse and on fusescope-engine, and reports the
> differences by fingerprint. It never runs in production. Its image
> comes from `fuseone-io/fusescope` (`cmd/parity`, `parity-image.yaml`),
> signed and attested by digest.

The values here are a schema and fictitious examples. A staging release
takes its real values, the promoted image digest included, from
`fusescope-infra`.

## What it installs

| Workload | Kind | ServiceAccount | Mounts |
|---|---|---|---|
| hourly round | CronJob `<release>-run-hourly` | `<release>-run` | settings, tenants, engine client, ClickHouse DSN, Pushgateway and Prometheus tokens, a report `emptyDir` |
| daily round | CronJob `<release>-run-daily` | `<release>-run` | as the hourly round |
| cleanup | CronJob `<release>-cleanup` | `<release>-cleanup` | settings |
| investigation | StatefulSet `<release>-investigate`, zero replicas | `<release>-investigate` | settings, tenants, engine client, ClickHouse DSN, Prometheus and audit tokens |

- **Pods:** every pod runs as `65532:65532`, with a read-only root, no
  privilege escalation, all capabilities dropped and the default seccomp
  profile. Every credential is mounted read-only.
- **Image:** pulled as `repository@digest`. A tag is refused.
- **Schedules:** times are UTC.
  - The hourly round skips every hour whose run could overlap the daily
    one.
  - Each run spans `startingDeadlineSeconds + activeDeadlineSeconds +
    marginSeconds` from its scheduled minute. The hourly round is checked
    against the daily one on both sides, round the clock.
  - A round's `activeDeadlineSeconds` must exceed its `budgetSeconds` by
    at least `marginSeconds`.
- **Settings:** the settings files are rendered into
  `<release>-settings`:
  - `hourly.yaml` and `daily.yaml` carry each round's budget;
  - `investigate.yaml` carries no round bounds.

  None of them holds a secret: the ClickHouse DSN comes from
  `credentials.clickhouse_dsn_file`.

## RBAC

The run keys live in their own namespace, `runKeys.namespace`, and
nothing else lives there.

| Who | Where | What |
|---|---|---|
| `<release>-run` | run keys | `create` on `secrets` |
| `<release>-cleanup` | run keys | `list` and `delete` on `secrets` |
| on-call (`oncall.group`) | run keys | `get` on `secrets` |
| on-call | release | `get`/`patch` on `statefulsets/scale` of `<release>-investigate`; `get` on `pods` and `create` on `pods/exec` of `<release>-investigate-0` |
| `<release>-investigate` | none | nothing; its token is mounted only because `parity investigate` refuses to run outside its pod |

- **Exec scope:** the investigation is a StatefulSet so that its one pod
  has a fixed name, which `pods/exec` is limited to. On-call can neither
  list pods nor exec into a round's.
- **Spec:** on-call holds only the `scale` subresource, so the image and
  the spec cannot be changed by them.

## What a release names

The chart creates no Secret. Each one below must exist in the release's
namespace, and they must all differ:

- `secrets.engineClient`:
  - `tls.crt` and `tls.key`, the parity's client identity on the engine;
  - `ca.crt`, the engine's CA;
  - `jwt.pem`, the key the parity signs tenant tokens with.
- `secrets.clickhouse`: `dsn`, the DSN of a `readonly = 1` user.
- `secrets.pushgateway`, `secrets.prometheus`, `secrets.audit`: `token`
  each.
- `tenants.configMap`: the tenants file D1 maintains.

## Egress

Each workload's NetworkPolicy accepts no ingress, and egress only to the
destinations it uses:

| Workload | Destinations |
|---|---|
| run | `dns`, `apiServer`, `engine`, `clickhouse`, `bucket`, `sts`, `prometheus`, `pushgateway` |
| cleanup | `dns`, `apiServer` |
| investigation | `dns`, `engine`, `clickhouse`, `bucket`, `sts`, `prometheus`, `audit`, `idp` |

- **Rules:** every destination a workload uses must be given. Each rule
  names its peers and its ports, and a peer of `0.0.0.0/0` or `::/0` is
  refused.
- **Outside the cluster:** S3, STS and the IdP are reached through VPC
  endpoints, or through the fixed egress proxy `proxy.url`.
  - With the proxy, `egress.proxy` replaces `bucket`, `sts` and `idp`.
  - `HTTPS_PROXY` is set for the rounds and the investigation.
  - `NO_PROXY` covers the cluster's own names and every in-cluster
    endpoint.

## Engine

The engine chart does not change. A staging release of it accepts the
parity through objects the infra creates:

- the parity's client CA, appended to `public-ca.crt` in
  `tls.clientCASecret`;
- the parity's public key, under its own `kid`, in `jwks.json` of
  `auth.jwksConfigMap`.

The engine accepts one issuer, so the parity signs with `auth.issuer`.

## Investigating a round

On-call, with the cluster's OIDC login. Here `parity` is the release's
namespace and `parity-run-keys` the run keys':

```sh
kubectl -n parity patch statefulset <release>-investigate --subresource=scale \
  --type=merge -p '{"spec":{"replicas":1}}'
kubectl -n parity get pod <release>-investigate-0        # until Running
kubectl -n parity-run-keys get secret parity-run-<run id> -o jsonpath='{.data.key}'
kubectl -n parity exec -it <release>-investigate-0 -- /parity investigate \
  -settings /etc/parity/settings/investigate.yaml -tenants /etc/parity/tenants/tenants.yaml \
  -run <run id> -tenant <org> -class settled -identity-fd tty -key-fd tty
kubectl -n parity patch statefulset <release>-investigate --subresource=scale \
  --type=merge -p '{"spec":{"replicas":0}}'
```

- **Prompts:** the investigation asks on the terminal for the operator's
  ID token, then for the key.
- **Audit:** it reports its start and its close to the audit pipeline.

## Checks

`scripts/fusescope-parity-chart-check.sh` checks everything above on the
rendered manifests: lint, `kubeconform`, the exact RBAC, the hardening and
the mounts, the schedules, the egress and the refusals. On a staging
cluster, `kubectl auth can-i` for each role confirms the grants.
