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
- With `tls.enabled` (the default), `tls.clientCASecret` holds three sets of
  client CAs. They are self-signed roots, and no two share a key:
  - `public-ca.crt` holds the backend's and the parity's client CAs, for
    Flight SQL;
  - `hot-ca.crt` holds the queriers' client CA, for the hot window;
  - `ingest-ca.crt` holds the collectors' client CA, for OTLP ingest. Only the
    ingester's configuration names it.

  Each key is projected by name. The ingester gets all three, the querier
  `public-ca.crt` and `hot-ca.crt`, and the compactor none. A Secret missing
  a key keeps the pod from starting.
- Also with `tls.enabled`, each serving role has its own identity,
  `tls.identities.ingester` and `tls.identities.querier`, each with
  `tls.crt` and `tls.key`:
  - the ingester's names `*.<release>-ingester-hot.<namespace>.svc` and
    `<release>-ingest`, and must not chain to `hot-ca.crt`. A collector
    trusts the CA that issued it;
  - the querier's names `<release>-flight` and is the one identity issued
    under `hot-ca.crt`. A Flight SQL client trusts that CA;
  - the compactor gets none.
- Also with `tls.enabled`, `tls.hotServerCAConfigMap` names a ConfigMap
  whose `ca-bundle.crt` holds the CA that issued the ingester's identity.
  The querier verifies the hot window against it; without it every hot scan
  fails and queries answer from flushed files alone.
  - **Querier only:** the bundle is mounted on the querier, at
    `/etc/fusescope/hot-server-ca/ca-bundle.crt`, as `SSL_CERT_FILE`. The
    ingester and the compactor get neither.
  - **Replaces the system's roots:** `SSL_CERT_FILE` is every TLS client of
    the querier's trust store, the bucket and the catalog included. The
    bundle must hold every root they need, such as a public store's.
  - **Not `hot-ca.crt`:** that CA authenticates the querier as a client. The
    ingester's identity never chains to it.
  - **Checked by name:** the key is projected by name, so a ConfigMap
    without `ca-bundle.crt` keeps the querier from starting.
- **Engine version:** this chart needs engine 0.0.2 or later.
  - From 0.0.2, an ingester with TLS does not start without
    `ingest_client_ca`.
  - Engine 0.0.1 refuses the key.
  - `appVersion` is 0.0.3.
- With `auth.mode=jwt` (the default, which requires TLS):
  `auth.jwksConfigMap`, a ConfigMap with `jwks.json`, and `auth.issuer`.

A pod reads its Secrets at start: after rotating one, change the role's
`rolloutTokens` entry or `kubectl rollout restart` it.

In staging, the parity (`fusescope-parity` chart) queries the engine as a
client of its own. It needs no change here:
- its client CA is appended to `public-ca.crt`;
- its public key, under its own `kid`, goes in `jwks.json`.

It signs with `auth.issuer`, the one issuer the engine accepts.

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
