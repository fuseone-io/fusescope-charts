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
| hourly round | CronJob `<release>-run-hourly` | `<release>-run` | settings, tenants, engine client, ClickHouse DSN, Pushgateway and Prometheus tokens, a report `emptyDir`; with a store of its own, `secrets.bucketRun` and the store's CA |
| daily round | CronJob `<release>-run-daily` | `<release>-run` | as the hourly round |
| cleanup | CronJob `<release>-cleanup` | `<release>-cleanup` | settings |
| investigation | StatefulSet `<release>-investigate`, zero replicas | `<release>-investigate` | settings, tenants, engine client, ClickHouse DSN, Prometheus and audit tokens; with a store of its own, `secrets.bucketInvestigate` and the store's CA |

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
  `<release>-settings`: `hourly.yaml`, `daily.yaml` and `investigate.yaml`.
  - All three carry the one `round` block. An investigation plans a window
    again with its report's seed and sample, so it must plan as the round
    did.
  - The rounds add only their `budgetSeconds`.
  - The block's keys are closed and bounded by the schema, and `budget` is
    not one of them.
  - None of the files holds a secret: the ClickHouse DSN comes from
    `credentials.clickhouse_dsn_file`.
- **Provenance:** every report records `build.backendCommit` (40 hex) and
  `build.engineVersion`, both required.

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
- `secrets.clickhouse`: `dsn`, the DSN of a `readonly = 2` user granted
  `SELECT` only. `readonly = 2` refuses writes, DDL and `SET readonly`, but
  lets a query carry its own settings: the backend sends `log_comment`, and
  `max_execution_time` when one is configured, with every query, and
  `readonly = 1` refuses them all.
- `secrets.pushgateway`, `secrets.prometheus`, `secrets.audit`: `token`
  each.
- `tenants.configMap`: the tenants file D1 maintains.
- `secrets.bucketRun` and `secrets.bucketInvestigate`, both or neither,
  for an S3-compatible store without workload identity. Each holds
  `credentials`, an AWS shared credentials file:
  - the rounds' may write reports and the requeue;
  - the investigation's only reads reports, since on-call can exec into
    its pod.

  Only the `credentials` key of each Secret is mounted, for its own
  workload, never for the cleanup. With them, `sts` is not a destination.
- `bucket.endpoint` (`https://` only) and `bucket.region` name the store,
  which must meet the store requirements below.
- `bucket.pathStyle` (default `false`) puts the bucket in the request path
  instead of the host name. It is never inferred from the endpoint. A store
  reached by a host name with no name per bucket, such as RustFS behind a
  Service, needs `true`; otherwise every request goes to
  `<bucket>.<host>`, which does not resolve, and the round ends with
  `parity_bucket`. AWS S3 keeps `false`. It needs an image built with
  `bucket.path_style` (`fuseone-io/fusescope#382` or later): an older one
  ignores it without a word.
  `bucket.caConfigMap`, a ConfigMap with `ca.crt`, holds the CA its
  certificate chains to; it is not a secret, so the two workloads share it.

## Trust

`trust.caConfigMap` names a ConfigMap whose `ca-bundle.crt` becomes
`SSL_CERT_FILE` for the rounds and the investigation, never for the cleanup.

- **Clients covered:** it is what the parity's HTTPS clients trust, for a
  deployment whose endpoints chain to a CA of its own:
  - Prometheus, the Pushgateway, the audit pipeline and the IdP;
  - the S3 SDK;
  - ClickHouse over TLS.

  The engine is not one of them: it keeps `ca.crt` of `secrets.engineClient`.
- **Replaces the system's roots:** a public endpoint needs its roots in the
  bundle too.
- **Checked:** only the ConfigMap's name. Helm cannot see whether the
  ConfigMap exists or holds `ca-bundle.crt`. Without either, the pod does
  not start.

## Store requirements

A store other than AWS S3 is accepted only if it honours what the
parity's guarantees rest on. A store that ignores any of these answers
`200`, so nothing fails: reports are overwritten, requeue updates are
lost, and the requeue is left unencrypted, all in silence.

- **No overwrite:** a `PutObject` with `If-None-Match: *` on a key that
  exists is refused with `412`. Reports are published this way, never
  replacing another.
- **Real CAS:** a `PutObject` with `If-Match` is refused when the ETag is
  not the object's current one (`412`), or when the key does not exist
  (`412` or `404`). The requeue is replaced this way.
- **SSE-KMS:**
  - a `PutObject` with `x-amz-server-side-encryption: aws:kms` and a key id
    the store does not hold is refused;
  - an object written with a valid key reports `aws:kms` and that key id
    on `HeadObject`.

| Store | Status |
|---|---|
| AWS S3 | the reference |
| RustFS 1.0.3, with its local KMS (`RUSTFS_KMS_ENABLE`, backend `local`) | validated: each requirement above checked with the parity's own client. **Requires `bucket.pathStyle: true`** |
| Google Cloud Storage, XML API (S3 interoperability) | **incompatible**, whatever `bucket.pathStyle` says: it accepts `If-None-Match`, `If-Match` and `aws:kms` and ignores all three. Its signing and checksum differences are not the obstacle. GCS support is wanted, through a port of its own in the parity: generation preconditions and the bucket's CMEK. That is separate work. |

Any other store must pass the same checks before a release points at it.
The demo rehearsal in `fusescope-infra` runs them as a preflight, on a
prefix of its own, before the parity's first round.

## Egress

Each workload's NetworkPolicy accepts no ingress, and egress only to the
destinations it uses:

| Workload | Destinations |
|---|---|
| run | `dns`, `apiServer`, `engine`, `clickhouse`, `bucket`, `sts`, `prometheus`, `pushgateway` |
| cleanup | `dns`, `apiServer` |
| investigation | `dns`, `engine`, `clickhouse`, `bucket`, `sts`, `prometheus`, `audit`, `idp` |

- **Rules:** every destination a workload uses must be given. Each rule
  names its peers and its ports, and every port names its `port`.
- **Peers:** a peer is one of:
  - an `ipBlock` no wider than `/8` (IPv4) or `/32` (IPv6);
  - a `podSelector` by `matchLabels`, with a `namespaceSelector` by
    `matchLabels` for another namespace.

  An empty peer, an empty selector or a selector without labels is
  refused, since each reaches more than it names.
- **A store of its own:** with `bucket.endpoint`, `egress.bucket` names it,
  ideally as a `/32`; `proxy.url` is refused beside it.
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
