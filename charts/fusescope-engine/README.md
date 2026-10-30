# FuseScope engine

> **Experimental and under construction.** The engine is the Parquet
> storage and query layer that will replace ClickHouse in FuseScope. It is
> not ready for production, its configuration still changes, and the
> `fusescope` chart installs it only with `engine.enabled=true`. Leave it off.
>
> **No official image is published yet.** `image.repository` is required:
> build the image from the engine repository (`make image`), push it to a
> registry the cluster pulls from, and set `image.repository` and
> `image.tag`.

Its source, design and operations live in
[fuseone-io/fusescope-engine](https://github.com/fuseone-io/fusescope-engine):
`docs/ops/image.md` for the image, `docs/ops/runbook.md` for the on-call
runbook, `docs/ops/dashboard.md` for the Grafana dashboard.

## What it installs

| Role | Workload | State | Service |
|---|---|---|---|
| ingester | StatefulSet | WAL on a `ReadWriteOnce` claim per pod | `<release>-ingest` (OTLP 4317), headless `<release>-ingester-hot` (8816) |
| querier | Deployment | spill on an `emptyDir` | `<release>-flight` (Flight SQL 8815) |
| compactor | Deployment, one holding the lease | none | none |
| migrator | pre-install and pre-upgrade hook Job | none | none |

Every pod runs as `65532:65532` with a read-only root, no privilege
escalation, all capabilities dropped, the default seccomp profile and no
API token. Each pod of the three roles has its own ServiceAccount and a
startup probe ahead of liveness and readiness on port 9464; the migration
Job runs under the namespace's `default` ServiceAccount, its token not
mounted either.

## What a release names

The chart creates no Secret; it refuses to render without these, or with
any two of them alike:

- `secrets.ingester`, `secrets.querier`, `secrets.compactor`: one Secret
  per role with `FS_CATALOG_URL`, `FS_BUCKET_ACCESS_KEY` and
  `FS_BUCKET_SECRET_KEY`, each its own Postgres user and bucket identity.
  `secrets.migrator` holds the one user allowed DDL, for the migration Job;
  no role migrates.
- With `tls.enabled` (the default): `tls.clientCASecret` with
  `public-ca.crt` (the backend's client CAs) and `hot-ca.crt` (the
  queriers'), two sets of self-signed roots sharing no key; and
  `tls.identities.ingester` and `tls.identities.querier`, each with
  `tls.crt` and `tls.key`. The ingester's names
  `*.<release>-ingester-hot.<namespace>.svc` and must not chain to
  `hot-ca.crt`; the querier's names `<release>-flight` and is the one
  identity issued under `hot-ca.crt`. The compactor gets none.
- With `auth.mode=jwt` (the default, which requires TLS):
  `auth.jwksConfigMap`, a ConfigMap with `jwks.json`, and `auth.issuer`.

A pod reads its Secrets at start: after rotating one, change the role's
`rolloutTokens` entry or `kubectl rollout restart` it.

`ci/staging-values.yaml` is the shape of a staging release and
`ci/dev-values.yaml` of a development one. Under the `fusescope` chart the
same values sit under `engine`.

## Checks

`scripts/fusescope-engine-chart-check.sh` checks the chart under the
`fusescope` chart too, through the packaged dependency `helm dependency
build` embeds: off by default it renders no engine object, on with the
staging values under `engine` it renders every role, the migration Job and
the ServiceAccounts, and on without them it is refused. Alone, it lints the chart strictly with each
`ci/` values file, validates the rendered objects with `kubeconform`,
checks that the roles keep their own Secret, ServiceAccount and identity,
mount no API token, never migrate and have a startup probe, and that every
refusal holds. Given `--image` or `--binary`, it also validates each
role's rendered configuration with that engine; the engine's CI does so on
every push against the image it builds.
