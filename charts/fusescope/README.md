
# FuseScope

![Version: 0.163.0](https://img.shields.io/badge/Version-0.163.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.161.0](https://img.shields.io/badge/AppVersion-0.161.0-informational?style=flat-square)

FuseScope is an open-source observability platform native to OpenTelemetry, with logs, traces and metrics in a single application. It is a hard fork of [SigNoz](https://github.com/SigNoz/signoz) maintained by FuseOne.

### TL;DR;

```sh
helm repo add fusescope https://fuseone-io.github.io/fusescope-charts
helm install -n platform --create-namespace "my-release" fusescope/fusescope
```

### Introduction

This chart bootstraps [FuseScope](https://github.com/fuseone-io/fusescope) cluster deployment on a
Kubernetes cluster using [Helm](https://helm.sh) package manager.

### Prerequisites

- Kubernetes 1.16+; 1.26+ for fusescope-schema's Job to stop at once on a refusal (`podFailurePolicy`), which earlier versions retry until `telemetryStoreMigrator.backoffLimit`
- Helm 3.0+

### Installing the Chart

To install the chart with the release name `my-release`:

```bash
helm repo add fusescope https://fuseone-io.github.io/fusescope-charts
helm -n platform --create-namespace install "my-release" fusescope/fusescope
```

These commands deploy FuseScope on the Kubernetes cluster in the default configuration.
The [Configuration](#configuration) section lists the parameters that can be configured during installation:

> **Tip**: List all releases using `helm list`

### Uninstalling the chart

To uninstall/delete the `my-release` resources:

```bash
helm -n platform uninstall "my-release"
```

See the [Helm docs](https://helm.sh/docs/helm/helm_uninstall/) for documentation on the helm uninstall command.

The command above removes all the Kubernetes components associated
with the chart and deletes the release.

Deletion of the StatefulSet doesn't cascade to deleting associated PVCs. To delete them:

```bash
kubectl -n platform delete pvc --selector app.kubernetes.io/instance=my-release
```

Sometimes everything doesn't get properly removed. If that happens try deleting the namespace:

```bash
kubectl delete namespace platform
```

### OTLP collector

The FuseScope collector (`fusescopeCollector`, [fusescope-collector-server](https://github.com/fuseone-io/fusescope-collector-server)) is the chart's OTLP collector: it receives OTLP over gRPC (4317) and HTTP (4318) and writes traces, logs and metrics, plus the span metrics it derives from traces, to ClickHouse directly. FuseScope manages its log pipelines, span attribute mapping and LLM pricing over OpAMP; it cannot change what the collector receives or where it writes.

- **Compat Service.** While `otelCollector.enabled` is false, the chart renders a Service with the earlier collector's name, `RELEASE-fusescope-otel-collector`, selecting the FuseScope collector's pods. Its `otlp` and `otlp-http` ports take their service ports, node ports and the Service type and annotations from `otelCollector.ports` and `otelCollector.service`. Agents, SDKs, the ingestion URL shown in FuseScope (`signoz.ingestionUrl`), the onboarding check and `otelCollector.ingress` keep that endpoint; `otelCollector.ingress` stays gated by its own `enabled` and now routes to this Service, so its paths must target the OTLP service ports. The collector's own Service, `RELEASE-fusescope-collector`, exposes the same ports.
- **Only OTLP.** The earlier collector's other receivers are not served: Jaeger gRPC (14250), Jaeger Thrift over HTTP (14268), Heroku logs (8081) and JSON logs (8082). Send that telemetry as OTLP, or keep the earlier collector.
- **Up to about 10 s before data shows.** The FuseScope collector batches each ClickHouse write for up to 10 s, where the earlier collector flushed every second: the service map joins a parent and a child span only within one insert, so longer batches keep it complete (collector-server `docs/spec/clickhouse-traces.md`). New telemetry can take about 10 s to appear.
- **OpAMP.** Without RUM the collector connects as a `writer` to FuseScope's in-cluster OpAMP listener (`ws://RELEASE-fusescope:4320/v1/opamp`), in plaintext by an explicit `tls.insecure`, the only transport FuseScope serves there until it adds TLS (fuseone-io/fusescope#261). It presents no token and needs no certificate. With `rum.enabled` it connects as `ingress` over TLS 1.3 to port 4321 (below).
- **Sizing.** `memory_limiter` refuses data above 80% of the memory limit (1Gi by default), so senders retry rather than the pod being OOM-killed. Set `fusescopeCollector.autoscaling.enabled` for an HPA on CPU and memory; the Deployment then leaves `replicas` to it.

### Real User Monitoring

With `fusescopeCollector.rum.enabled`, the FuseScope collector also receives RUM: browsers and apps send OTLP/HTTP to `POST /rum/v1/traces` and `POST /rum/v1/logs`, authenticated by the application's public key, and the collector writes ClickHouse directly. The chart no longer configures the FuseScope backend's own RUM gateway, which is being removed. The collector takes the RUM applications and keys from FuseScope as the ingest policy, over OpAMP with TLS 1.3 on a second FuseScope listener (`signoz.ingestPolicy`, port 4321), and reports what it accepted for the RUM setup screen. It needs a FuseScope release with that listener (fuseone-io/fusescope#314).

```yaml
signoz:
  ingestPolicy:
    tokens:
      existingSecret: fusescope-ingest-tokens   # key "tokens": one token per line, 32-256 characters
    tls:
      certManager:
        enabled: true
        issuerRef: {name: internal-ca}          # a CA issuer, so ca.crt is set for the collector
fusescopeCollector:
  enabled: true
  rum:
    enabled: true
    tls:
      certManager:
        enabled: true
        issuerRef: {name: internal-ca}
  ingress:
    enabled: true                               # /rum/v1/traces and /rum/v1/logs on the signoz.ingress hosts and TLS
```

- **Token.** Create the Secret before installing, e.g. `kubectl create secret generic fusescope-ingest-tokens --from-literal=tokens=$(openssl rand -hex 32)`. FuseScope accepts any token in it and the collector presents the same one; to rotate, give the collector its own Secret (`fusescopeCollector.ingestToken`), add the new token to FuseScope's, switch the collector, then remove the old one. FuseScope reads the tokens at start.
- **Android 6–9.** Set `fusescopeCollector.rum.tlsMinVersion: "1.2"` to accept TLS 1.2 from stock Android API 23–28: the collector (0.3.1 and later) then allows only ECDHE AEAD suites, AES-GCM and ChaCha20-Poly1305 ([collector ADR 0009](https://github.com/fuseone-io/fusescope-collector-server/blob/main/docs/adr/0009-rum-tls-compatibility.md)), and modern clients still negotiate TLS 1.3. The public proxy must also accept TLS 1.2 with those suites on the RUM endpoint; the proxy-to-collector hop can stay TLS 1.3. Do not lower a shared non-RUM listener implicitly. OpAMP stays TLS 1.3, and the SDK needs no TLS dependency. Device acceptance on API 23 and 28 is tracked in [#337](https://github.com/fuseone-io/fusescope/issues/337).
- **Certificates.** OpAMP uses TLS 1.3; RUM defaults to TLS 1.3 (`fusescopeCollector.rum.tlsMinVersion`), with a certificate from a Secret (`existingSecret`, a `kubernetes.io/tls` Secret) or a cert-manager Certificate. The collector verifies FuseScope's against the Secret's `ca.crt`; set `signoz.ingestPolicy.tls.caKey: ""` for a certificate from a public CA. Renewals are picked up without a restart.
- **Readiness.** The collector is ready only while it holds a valid ingest policy, so RUM reaches it only once FuseScope has published one. Until then, and if FuseScope never does (no token, wrong certificate), the pod runs but stays out of the Service; its log says why.
- **Ingress.** The collector's Ingress re-encrypts to its TLS listener. The default annotations are ingress-nginx's (`backend-protocol: HTTPS`, `proxy-body-size: 4m`); set the equivalents for another controller. It takes only `/rum/v1/traces` and `/rum/v1/logs` (`Exact`), more specific than the FuseScope ingress's `/`, so both share a host and the browser SDK FuseScope serves at `/rum/v1/sdk/` stays on the FuseScope ingress.
- **CORS belongs to the collector.** It answers `OPTIONS` preflights from each application's allowed origins. The ingress must pass `OPTIONS` and the `Origin` header through and must not add CORS headers of its own: with ingress-nginx, don't set `nginx.ingress.kubernetes.io/enable-cors`.
- **Client IP.** The per-client rate limit (20 req/s, burst 60) keys on the client IP, taken from `X-Forwarded-For` only when the peer is in `fusescopeCollector.rum.trustedProxies`, walking the header from the right past trusted addresses. With the ingress on, the private ranges are trusted by default; keep the real client IP reaching the controller (e.g. `externalTrafficPolicy: Local` or PROXY protocol).
- **Usage and filter suggestions.** The collector counts ingested spans, log records and data points each hour, per service and ingestion key, into `signoz_meter` for Meter Explorer and Ingestion Settings (`fusescopeCollector.meter.enabled`); span metrics and its own telemetry are not counted, each in a pipeline of its own. It also records the distinct attribute sets it writes into `signoz_metadata`, for the related values of filter suggestions (`fusescopeCollector.attributesMetadata.enabled`). Both are on by default, bounded, and never delay or fail the data path.

### Agents

With `fusescopeAgent.enabled`, a DaemonSet runs the FuseScope collector in agent mode on each node: pod logs (`/var/log/pods`), host metrics and kubelet stats, with pod attributes, sent to the collector (the gateway) over OTLP/gRPC. It writes no storage and takes no configuration over OpAMP. The gateway receives them on a listener of its own, `fusescopeCollector.agentListener` (port 4322, as 4319 is RUM's), which requires all three of TLS 1.3, a client certificate its client CA signed, and the agents' token. The OTLP ports 4317 and 4318 stay as they are, without TLS, for SDKs inside the cluster.

```yaml
fusescopeCollector:
  agentListener:
    enabled: true
    tls:
      certManager:
        enabled: true
        issuerRef: {name: internal-ca}   # a CA issuer, so ca.crt is set
    token:
      existingSecret: fusescope-agent-token
fusescopeAgent:
  enabled: true
  tls:
    certManager:
      enabled: true
      issuerRef: {name: internal-ca}
```

- **Token.** Create it before installing, e.g. `kubectl create secret generic fusescope-agent-token --from-literal=token=$(openssl rand -hex 32)`. The agents and the gateway read the same Secret, as files; the token never goes in values.
- **Certificates.** One client certificate for every agent of the release (`fusescopeAgent.tls`), not one per pod, and one server certificate for the listener (`fusescopeCollector.agentListener.tls`). Each is a `kubernetes.io/tls` Secret you provide (`existingSecret`) or a cert-manager Certificate the chart creates. The gateway verifies agents with the `ca.crt` of the agents' Secret, or a bundle in `agentListener.clientCA`; the agents verify the gateway with the `ca.crt` of the listener's Secret, or a bundle in `fusescopeAgent.gateway.ca`. Pods mount only the CA bundle of the other side's Secret, never its key.
- **Rotation.** cert-manager renews both certificates before they expire (`renewBefore`) with a new key each time; the collectors read the renewed files without a restart. With `existingSecret`, update the Secret in place with a certificate from the same CA. To rotate the token, update its Secret: the gateway and the agents read it again, and agents with the old token are refused until they have the new one, so expect a short gap.
- **Replacing the CA.** Trust both CAs before any certificate changes, then move certificates, then drop the old CA:
  1. Put the old and the new CA in one bundle, in a Secret of its own, and point both sides at it: `fusescopeCollector.agentListener.clientCA.existingSecret` and `fusescopeAgent.gateway.ca.existingSecret`. Upgrade, and wait until every agent pod has rolled.
  2. Issue the listener's and the agents' certificates from the new CA (switch the `issuerRef`, or replace the `existingSecret`s).
  3. Remove the old CA from the bundle, or unset both `existingSecret`s to go back to each Secret's `ca.crt`.
- **Network.** `fusescopeCollector.agentListener.networkPolicy` (on by default) adds a NetworkPolicy to the collector pods: the agents' port accepts only this release's agent pods, and the other ports keep accepting from anywhere. It needs a CNI that enforces NetworkPolicy.
- **Privileges.** The agent runs as root, to read pod logs, which nodes keep readable by root only; its root filesystem is read-only and every capability is dropped. It mounts `/var/log/pods` and the host root read-only, and keeps log read offsets in `fusescopeAgent.statePath` on the node. Its ClusterRole reads pods, namespaces, nodes, replica sets and `nodes/stats`.
- **Kubelet.** Kubelet stats are read from `https://NODE_NAME:10250` with the agent's service account and verify the kubelet's serving certificate. Where kubelets serve a self-signed one, `fusescopeAgent.kubeletStats.insecureSkipVerify` turns the check off, or disable `kubeletStats`.
- **Another gateway.** To send to a gateway outside this release, set `fusescopeAgent.gateway.endpoint` and `fusescopeAgent.gateway.ca.existingSecret`, and give both the same token Secret name (`fusescopeCollector.agentListener.token`).

### MCP server

The [FuseScope MCP server](https://github.com/fuseone-io/fusescope-mcp-server) lets AI assistants (Claude, Cursor, VS Code, …) query FuseScope. With `mcpServer.enabled` the chart runs it in HTTP mode, calling only this release's backend Service; `/mcp` on the FuseScope host routes to it when the ingress is on (see MCP Server in [Values](#values)).

```yaml
mcpServer:
  enabled: true
  ingress:
    enabled: true   # same host and TLS as signoz.ingress
```

- **Per-user keys.** No key is stored by default: each client sends its own FuseScope API key in the `SIGNOZ-API-KEY` header (or `Authorization: Bearer`), so each user gets their own role. For example `claude mcp add --transport http fusescope https://fusescope.example.com/mcp --header "SIGNOZ-API-KEY: <key>"`.
- **Shared key.** `mcpServer.apiKey.existingSecret` gives the server a key for clients that send none. Everyone who reaches the endpoint then acts with that key's role: use a Viewer service account and keep the endpoint private.
- **Pinned backend.** `FUSESCOPE_URL` and `FUSESCOPE_INSTANCE_URL_ALLOWLIST` are both the backend Service (`mcpServer.fusescopeUrl` overrides them), so a client's `X-SigNoz-URL` cannot point the server at another host.
- **Path.** The server serves `/mcp` itself, so the ingress forwards the path unchanged; no rewrite or base path is needed. Set `mcpServer.ingress.hosts` (and `tls`) for a dedicated host instead.
- **OAuth** is not configured by the chart: its sign-in page asks each user for a FuseScope URL, which the allowlist pins to the in-cluster Service.
- **NetworkPolicy.** `mcpServer.networkPolicy.enabled` admits this namespace and `ingress-nginx` (`ingressFrom`), and allows egress to the backend, DNS, and HTTPS to public addresses for the docs index refresh from `docs.fusescope.fuseone.io`. Set `docsRefreshInterval` and `docsFullRefreshInterval` to `"0"` to serve the bundled docs and drop that egress.

### Cold storage

ClickHouse can keep parts older than each signal's move period on object storage, where they stay queryable. The recommended production layout keeps 7 days on the local disk and the rest of retention in a bucket; metrics stay local unless you opt in. Turn it on with `clickhouse.coldStorage` (see ClickHouse Cold Storage in [Values](#values)), then set **Move to object storage** per signal on the retention settings page.

```yaml
clickhouse:
  coldStorage:
    enabled: true
    endpoint: https://my-bucket.s3.eu-west-1.amazonaws.com/data/
    region: eu-west-1
    existingSecret: fusescope-cold-storage   # keys accessKey and secretAccess
    cache:
      maxSize: 50Gi
```

The chart renders a disk for the bucket, a filesystem cache disk in front of it and a storage policy `tiered` with volumes `default` (local) and `s3` (cache over the bucket). The cold volume does not merge parts (`prefer_not_to_merge`), and zero-copy replication is off, so each replica stores its own copy. Rendering fails when `endpoint` or credentials are missing. Keys reach ClickHouse as environment variables from a Secret, never inline in the ClickHouse config.

| Store | Values | Auth |
|---|---|---|
| AWS S3 | `type: s3` | Keys from a Secret, or an IAM role (IRSA) with `role.enabled` and `role.annotations` |
| GCS | `type: gcs` (S3-compatible XML API, `support_batch_delete = false`) | HMAC keys of a service account (Cloud Storage → Settings → Interoperability). Workload identity is not supported |
| MinIO, Cloudflare R2, Backblaze B2, Wasabi, Ceph RGW | `type: s3` with the provider endpoint | Keys from a Secret |
| Azure Blob Storage | Not supported yet | |

- **Sizing.** Set `cache.maxSize` to the larger of 10 % of the cold data and 2 days of compressed ingest. Size the ClickHouse data volume (`clickhouse.persistence.size`) for hot data + cache + about 1 % of the cold data for metadata.
- **Latency.** The first query on cold data takes up to about a second; repeats are served from the cache and are close to local. After a restart or a cache eviction the first queries are slow again.
- **Dedicated bucket.** The bucket must have no lifecycle rules and no other writers: deleting objects behind ClickHouse corrupts parts. ClickHouse deletes cold data itself when retention expires.
- **Backups.** Snapshots or backups of the local volume do not contain cold data.
- **Network.** On AWS, reach S3 through a gateway VPC endpoint to avoid NAT gateway charges.
- **External ClickHouse.** With `externalClickhouse`, define the storage policy yourself with the same names, policy `tiered` and volume `s3`: FuseScope depends on them.

> [!WARNING]
> ### Breaking Changes
> #### Version 0.162.1
> fusescope-schema 0.4.1 applies its migration `0002` on the upgrade: it inserts the base rows of `signoz_metadata.column_evolution_metadata` that the earlier collector's migrator left and that an install by 0.162.0 lacks, and keeps the rows already there.
>
> After `0002` there is no going back as before:
> - `telemetryStoreMigrator.migrator: fork` is no longer supported.
> - A plain `helm rollback` to 0.162.0 does not work either: it brings back fusescope-schema 0.4.0, which refuses the unknown `0002` in the history, so the Job fails and the collectors' init containers never let them start.
> - To run 0.162.0's manifests, keep fusescope-schema 0.4.1: set `telemetryStoreMigrator.image.tag: "0.4.1"` and `telemetryStoreMigrator.image.digest: sha256:9951f2479ac6e5150b116cd856569aaae6ed921e9b951f0fd9c93160e7311077`. Otherwise, restore a backup taken before `0002`.
>
> fusescope-schema 0.4.1 also binds seven of the schema's views to the user the migrator connects as, instead of `default`, on a new install; existing views bound to `default` are kept. See [`0002`](https://github.com/fuseone-io/fusescope-collector-server/blob/main/docs/spec/fusescope-schema.md#53-0002-column_evolution_baseline) and [view definers](https://github.com/fuseone-io/fusescope-collector-server/blob/main/docs/spec/fusescope-schema.md#54-view-definers).
>
> #### Version 0.162.0
> The schema is migrated by fusescope-schema, the FuseScope schema migrator, a second binary of the FuseScope collector image (`telemetryStoreMigrator.migrator: fusescope-schema`). On an upgrade it adopts the schema the earlier collector's migrator created (fusescope-otel-collector 0.145.0), with no change to the telemetry tables, and refuses any other schema, listing the differences. The Job runs `migrate`; the collectors' init container waits with `check --wait`. Both read one connection from a ConfigMap and the password only from a Secret mounted as a file. The Job is no longer a Helm hook: it is named by a hash of its whole spec and `telemetryStoreMigrator.runId`. An upgrade that changes neither leaves it alone, finished or still running; one that changes its spec runs a new Job, a no-op on an up-to-date schema. After a failure, fix the cause and set a new `runId` to run it again, with Helm or Argo CD. An upgrade that changes the Job's spec, or its `runId`, while a migration runs stops that migration, which then needs `repair`: see [A chart upgrade that replaced a running Job](https://github.com/fuseone-io/fusescope-collector-server/blob/main/docs/spec/fusescope-schema.md#102-a-chart-upgrade-that-replaced-a-running-job).
>
> - `telemetryStoreMigrator.enableReplication: false` now fails the install: fusescope-schema migrates only the replicated schema.
> - The chart's ClickHouse gets `keeper_map_path_prefix` (`clickhouse.defaultSettings`), which restarts its pods once on the upgrade. An external ClickHouse needs it set, on every replica, with Keeper or ZooKeeper, the `shard` and `replica` macros and the cluster in `remote_servers`.
> - To keep the earlier collector's migrator, set `telemetryStoreMigrator.migrator: fork`. Going back to it is possible only while fusescope-schema has recorded `0001` alone.
>
> #### Version 0.161.0
> The FuseScope collector (`fusescopeCollector`) is now the default OTLP collector, and the earlier collector (`otelCollector`, fusescope-otel-collector) is off by default (`otelCollector.enabled: false`). A Service named like the earlier collector, with its OTLP ports, now selects the FuseScope collector, so OTLP endpoints keep working; the earlier collector's other receivers (Jaeger gRPC and Thrift/HTTP, Heroku and JSON logs) are not served, and new telemetry can take about 10 s to appear, where it took about 1 s. Its image still runs the schema migrations.
>
> To keep the earlier collector:
> ```yaml
> otelCollector:
>   enabled: true
> fusescopeCollector:
>   otlp:
>     enabled: false
> ```
>
> RUM no longer comes with `fusescopeCollector.enabled`: installs that enabled the collector for RUM must set `fusescopeCollector.rum.enabled: true`. Without it the RUM listener, its certificate and Ingress, the ingest token and FuseScope's ingest policy listener are not rendered.
>
> #### Version 0.131.0
> ClickHouse has been upgraded from `25.5.6` to `25.12.5`. This is a significant ClickHouse version jump, so review the upgrade guide before upgrading to avoid issues with your existing data.
>
> See the [upgrade guide](https://signoz.io/docs/operate/migration/upgrade-0-131) for details.
>
> #### Version 0.116.1
> Support for legacy environment variable by using following values has been removed from the chart templates and users must migrate any custom templates or values that relied on the legacy env behavior:
> - `signoz.configVars` has been remove
> - `signoz.smtpVars` has been removed
> - `signoz.additionalEnvs` has been removed
>
> #### Version 0.113.0
> `schemaMigrator` has been deprecated and replaced by `telemetryStoreMigrator`.
>
> Store migrations are now handled by a single Job using the built-in `migrate` command in `signoz-otel-collector`.
> If you had any overrides in `schemaMigrator`, move them to `telemetryStoreMigrator`. See the [upgrade guide](https://signoz.io/docs/operate/migration/upgrade-0.113) for details.
>
> The following `initContainers` have been removed as they are no longer required:
> - `signoz.initContainers.init`
> - `signoz.initContainers.migration`
> - `otelCollector.initContainers.init`
>
> Otel-collector no longer depends on the migrator Job existing. Readiness is now determined by a ClickHouse-based check (`migrate sync check`). If you had any of these overrides, remove them from your values.
>
> **Helm value reference (v0.113.0)** 
>
> Use the table below when migrating your `values.yaml`.
>  - Keys marked **Replaced** should be moved to the new path.
>  - Keys marked **Deprecated** have no replacement, so remove them from your overrides.
>
> | Key | Status | Replacement |
> | --- | --- | --- |
> | `signoz.initContainers.init` | Deprecated | None |
> | `signoz.initContainers.migration` | Deprecated | None |
> | `otelCollector.initContainers.init` | Deprecated | None |
> | `schemaMigrator.enabled` | Replaced | `telemetryStoreMigrator.enabled` |
> | `schemaMigrator.name` | Replaced | `telemetryStoreMigrator.name` |
> | `schemaMigrator.annotations` | Replaced | `telemetryStoreMigrator.annotations` |
> | `schemaMigrator.upgradeHelmHooks` | Replaced | `telemetryStoreMigrator.upgradeHelmHooks` |
> | `schemaMigrator.enableReplication` | Replaced | `telemetryStoreMigrator.enableReplication` |
> | `schemaMigrator.nodeSelector` | Replaced | `telemetryStoreMigrator.nodeSelector` |
> | `schemaMigrator.tolerations` | Replaced | `telemetryStoreMigrator.tolerations` |
> | `schemaMigrator.affinity` | Replaced | `telemetryStoreMigrator.affinity` |
> | `schemaMigrator.topologySpreadConstraints` | Replaced | `telemetryStoreMigrator.topologySpreadConstraints` |
> | `schemaMigrator.resources` | Replaced | `telemetryStoreMigrator.resources` |
> | `schemaMigrator.serviceAccount` | Replaced | `telemetryStoreMigrator.serviceAccount` |
> | `schemaMigrator.image` | Deprecated | None (uses otel-collector image) |
> | `schemaMigrator.args` | Deprecated | None |
> | `schemaMigrator.initContainers` | Deprecated | None |
> | `schemaMigrator.role` | Deprecated | None |
>
> #### Version 0.89.0
> After August 28, 2025, Bitnami will require paid subscriptions for their image updates. FuseScope utilises Bitnami container images and Helm charts for Zookeeper.
>
> To ensure continued stability, we have migrated the Zookeeper Images and Charts to our own repositories.
>
> You must upgrade to FuseScope `v0.89.0` to avoid any service interruption.
> More details are available in [Issue #731](https://github.com/SigNoz/charts/issues/731)
> #### Version 0.88.0
> **Configuration Migration Required:**
> - `signoz.configVars` has been deprecated
> - `signoz.smtpVars` has been deprecated
> - `signoz.additionalEnvs` has been deprecated
> These configuration options must now be specified under `signoz.env` instead.
>
> Refer to the official [documentation](https://github.com/fuseone-io/fusescope/blob/main/conf/example.yaml) for a complete list of env variables.
> <br/> Note on Variable Naming: Environment variables are derived from the YAML configuration.
> <br/> For example, a key `address` for `smtp` under the `emailing` section becomes `signoz_emailing_smtp_address`.
>
> **Before:**
> ```yaml
> signoz:
>  configVars:
>    storage: clickhouse
>  smtpVars:
>    existingSecret:
>      name: my-secret-name
>      hostKey: my-smtp-host-key
>      portKey: my-smtp-port-key
> ```
>
> **After:**
> ```yaml
> signoz:
>  env:
>    storage: clickhouse
>    signoz_emailing_smtp_address:
>      valueFrom:
>        secretKeyRef:
>          name: my-secret-name
>          key: my-smtp-address-key
> ```

## Values

<h3>Global Settings</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="global"><a href="./values.yaml#L3">global</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">cloud: other
clusterDomain: cluster.local
clusterName: ""
imagePullSecrets: []
imageRegistry: null
storageClass: null</pre>
</div>
            </td>
            <td>Global override values for the chart.</td>
        </tr>
        <tr>
            <td id="global--imageRegistry"><a href="./values.yaml#L7">global.imageRegistry</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Overrides the Image registry globally for all components.</td>
        </tr>
        <tr>
            <td id="global--imagePullSecrets"><a href="./values.yaml#L11">global.imagePullSecrets</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Global Image Pull Secrets.</td>
        </tr>
        <tr>
            <td id="global--storageClass"><a href="./values.yaml#L17">global.storageClass</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Overrides the storage class for all PVCs with persistence enabled. If not set, the default storage class is used. If set to "-", storageClassName will be an empty string, which disables dynamic provisioning.</td>
        </tr>
        <tr>
            <td id="global--clusterDomain"><a href="./values.yaml#L22">global.clusterDomain</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">cluster.local</pre>
</div>
            </td>
            <td>The Kubernetes cluster domain. It is used only when components are installed in different namespaces.</td>
        </tr>
        <tr>
            <td id="global--clusterName"><a href="./values.yaml#L27">global.clusterName</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>The Kubernetes cluster name. It is used to attach to telemetry data via the resource detection processor.</td>
        </tr>
        <tr>
            <td id="global--cloud"><a href="./values.yaml#L34">global.cloud</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">other</pre>
</div>
            </td>
            <td>The Kubernetes cluster cloud provider and distribution (if any). example: `aws`, `azure`, `gcp`, `gcp/autogke`, `hcloud`, `other` The storage class for persistent volumes is selected based on this value. When set to 'aws' or 'gcp' with `installCustomStorageClass` enabled, a new expandable storage class is created.</td>
        </tr>
    </tbody>
</table>
<h3>General Settings</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="nameOverride"><a href="./values.yaml#L38">nameOverride</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Override the default chart name.</td>
        </tr>
        <tr>
            <td id="fullnameOverride"><a href="./values.yaml#L42">fullnameOverride</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Override the default full chart name.</td>
        </tr>
        <tr>
            <td id="clusterName"><a href="./values.yaml#L46">clusterName</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Name of the K8s cluster. Used by SigNoz OtelCollectors to attach to telemetry data.</td>
        </tr>
        <tr>
            <td id="imagePullSecrets"><a href="./values.yaml#L52">imagePullSecrets</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Image Registry Secret Names for all SigNoz components. If `global.imagePullSecrets` is set, it will be merged with this list. This has lower precedence than `imagePullSecrets` at the individual component level.</td>
        </tr>
    </tbody>
</table>
<h3>External ClickHouse</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="externalClickhouse"><a href="./values.yaml#L732">externalClickhouse</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">cluster: cluster
database: signoz_metrics
existingSecret: null
existingSecretPasswordKey: null
host: null
httpPort: 8123
logDatabase: signoz_logs
meterDatabase: signoz_meter
password: ""
secure: false
tcpPort: 9000
traceDatabase: signoz_traces
user: ""
verify: false</pre>
</div>
            </td>
            <td>External ClickHouse configuration. Required when `clickhouse.enabled` is false.</td>
        </tr>
    </tbody>
</table>
<h3>SigNoz</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="signoz"><a href="./values.yaml#L778">signoz</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Default values for SigNoz.</td>
        </tr>
        <tr>
            <td id="signoz--name"><a href="./values.yaml#L782">signoz.name</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">signoz</pre>
</div>
            </td>
            <td>The name of the SigNoz component.</td>
        </tr>
        <tr>
            <td id="signoz--replicaCount"><a href="./values.yaml#L786">signoz.replicaCount</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">1</pre>
</div>
            </td>
            <td>The number of pod replicas for SigNoz.</td>
        </tr>
        <tr>
            <td id="signoz--image"><a href="./values.yaml#L789">signoz.image</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">pullPolicy: IfNotPresent
registry: ghcr.io
repository: fuseone-io/fusescope
tag: 0.161.0</pre>
</div>
            </td>
            <td>Image configuration for SigNoz.</td>
        </tr>
        <tr>
            <td id="signoz--imagePullSecrets"><a href="./values.yaml#L807">signoz.imagePullSecrets</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Image pull secrets for SigNoz. This has higher precedence than the root level or global value.</td>
        </tr>
        <tr>
            <td id="signoz--serviceAccount"><a href="./values.yaml#L810">signoz.serviceAccount</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
create: true
name: null</pre>
</div>
            </td>
            <td>Service Account configuration for SigNoz.</td>
        </tr>
        <tr>
            <td id="signoz--annotations"><a href="./values.yaml#L854">signoz.annotations</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Annotations for the SigNoz pod.</td>
        </tr>
        <tr>
            <td id="signoz--config"><a href="./values.yaml#L861">signoz.config</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>FuseScope configuration file (see conf/example.yaml in fuseone-io/fusescope), rendered into a ConfigMap and passed with --config. Use it for settings that do not fit environment variables, e.g. SSO domains under `authdomain.domains`. Reference secrets as ${NAME} and provide them through `signoz.env`.</td>
        </tr>
        <tr>
            <td id="signoz--additionalArgs"><a href="./values.yaml#L865">signoz.additionalArgs</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Additional command-line arguments for SigNoz.</td>
        </tr>
        <tr>
            <td id="signoz--env"><a href="./values.yaml#L889">signoz.env</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">signoz_alertmanager_provider: signoz
signoz_alertmanager_signoz_external__url: http://localhost:8080
signoz_emailing_enabled: false
signoz_prometheus_active__query__tracker_enabled: false
signoz_telemetrystore_provider: clickhouse</pre>
</div>
            </td>
            <td>Environment variables for SigNoz. Refer to the official documentation for a complete list: https://github.com/fuseone-io/fusescope/blob/main/conf/example.yaml Note on Variable Naming: Environment variables are derived from the YAML configuration. For example, a key `provider` under the `telemetry_store` section becomes `signoz_telemetrystore_provider`.</td>
        </tr>
        <tr>
            <td id="signoz--podSecurityContext"><a href="./values.yaml#L906">signoz.podSecurityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Pod-level security context.</td>
        </tr>
        <tr>
            <td id="signoz--podAnnotations"><a href="./values.yaml#L912">signoz.podAnnotations</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Annotations for the SigNoz pod.</td>
        </tr>
        <tr>
            <td id="signoz--securityContext"><a href="./values.yaml#L916">signoz.securityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Container-level security context.</td>
        </tr>
        <tr>
            <td id="signoz--additionalVolumeMounts"><a href="./values.yaml#L927">signoz.additionalVolumeMounts</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Additional volume mounts for the SigNoz container.</td>
        </tr>
        <tr>
            <td id="signoz--additionalVolumes"><a href="./values.yaml#L931">signoz.additionalVolumes</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Additional volumes for the SigNoz pod.</td>
        </tr>
        <tr>
            <td id="signoz--livenessProbe"><a href="./values.yaml#L935">signoz.livenessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Liveness probe configuration.</td>
        </tr>
        <tr>
            <td id="signoz--readinessProbe"><a href="./values.yaml#L947">signoz.readinessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Readiness probe configuration.</td>
        </tr>
        <tr>
            <td id="signoz--customLivenessProbe"><a href="./values.yaml#L959">signoz.customLivenessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Custom liveness probe to override the default.</td>
        </tr>
        <tr>
            <td id="signoz--customReadinessProbe"><a href="./values.yaml#L963">signoz.customReadinessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Custom readiness probe to override the default.</td>
        </tr>
        <tr>
            <td id="signoz--resources"><a href="./values.yaml#L1065">signoz.resources</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Resource requests and limits. Ref: http://kubernetes.io/docs/user-guide/compute-resources/</td>
        </tr>
        <tr>
            <td id="signoz--priorityClassName"><a href="./values.yaml#L1076">signoz.priorityClassName</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Priority class for the SigNoz pods.</td>
        </tr>
        <tr>
            <td id="signoz--nodeSelector"><a href="./values.yaml#L1080">signoz.nodeSelector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Node selector for pod assignment.</td>
        </tr>
        <tr>
            <td id="signoz--tolerations"><a href="./values.yaml#L1084">signoz.tolerations</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Tolerations for pod assignment.</td>
        </tr>
        <tr>
            <td id="signoz--affinity"><a href="./values.yaml#L1088">signoz.affinity</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Affinity settings for pod assignment.</td>
        </tr>
        <tr>
            <td id="signoz--topologySpreadConstraints"><a href="./values.yaml#L1092">signoz.topologySpreadConstraints</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Topology spread constraints for pod distribution.</td>
        </tr>
        <tr>
            <td id="signoz--persistence"><a href="./values.yaml#L1095">signoz.persistence</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">accessModes:
    - ReadWriteOnce
enabled: true
existingClaim: ""
size: 1Gi
storageClass: null</pre>
</div>
            </td>
            <td>Persistence configuration for the internal SQLite database.</td>
        </tr>
    </tbody>
</table>
<h3>SigNoz Networking</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="signoz--service"><a href="./values.yaml#L823">signoz.service</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
internalNodePort: null
internalPort: 8085
labels: {}
nodePort: null
opampInternalNodePort: null
opampPort: 4320
port: 8080
type: ClusterIP</pre>
</div>
            </td>
            <td>Service configuration for SigNoz. This allows you to configure how SigNoz is exposed within the Kubernetes cluster.</td>
        </tr>
        <tr>
            <td id="signoz--ingress"><a href="./values.yaml#L966">signoz.ingress</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
className: ""
enabled: false
hosts:
    - host: signoz.domain.com
      paths:
        - path: /
          pathType: ImplementationSpecific
          port: 8080
tls: []</pre>
</div>
            </td>
            <td>Ingress configuration for SigNoz.</td>
        </tr>
        <tr>
            <td id="signoz--ingestionUrl"><a href="./values.yaml#L998">signoz.ingestionUrl</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">The collector ingress (https when its host has TLS), else http://RELEASE-otel-collector.NAMESPACE.svc:4318</pre>
</div>
            </td>
            <td>OTLP/HTTP URL FuseScope shows in onboarding for sending telemetry (`global.ingestion_url`). An admin can still override it from the UI.</td>
        </tr>
    </tbody>
</table>
<h3>SigNoz Ingest Policy</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="signoz--ingestPolicy--port"><a href="./values.yaml#L1008">signoz.ingestPolicy.port</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">4321</pre>
</div>
            </td>
            <td>Port of the OpAMP listener with TLS.</td>
        </tr>
        <tr>
            <td id="signoz--ingestPolicy--tokens--existingSecret"><a href="./values.yaml#L1015">signoz.ingestPolicy.tokens.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Secret holding the ingress collectors' tokens, one per line, 32 to 256 characters each, so a new token can be added before the old one is removed. The FuseScope collector presents the same Secret's token unless `fusescopeCollector.ingestToken` names another; it then needs exactly one token in it.</td>
        </tr>
        <tr>
            <td id="signoz--ingestPolicy--tokens--secretKey"><a href="./values.yaml#L1018">signoz.ingestPolicy.tokens.secretKey</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">tokens</pre>
</div>
            </td>
            <td>Key in `existingSecret` holding the tokens.</td>
        </tr>
        <tr>
            <td id="signoz--ingestPolicy--tls--existingSecret"><a href="./values.yaml#L1024">signoz.ingestPolicy.tls.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>`kubernetes.io/tls` Secret with the listener's `tls.crt` and `tls.key` for the FuseScope Service name, and the `ca.crt` the FuseScope collector verifies it with. Read again when it changes: a renewal needs no restart.</td>
        </tr>
        <tr>
            <td id="signoz--ingestPolicy--tls--caKey"><a href="./values.yaml#L1028">signoz.ingestPolicy.tls.caKey</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">ca.crt</pre>
</div>
            </td>
            <td>Key in the Secret holding the CA the FuseScope collector trusts; empty, the collector trusts the system roots.</td>
        </tr>
        <tr>
            <td id="signoz--ingestPolicy--tls--certManager"><a href="./values.yaml#L1033">signoz.ingestPolicy.tls.certManager</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">duration: 2160h
enabled: false
issuerRef:
    group: cert-manager.io
    kind: Issuer
    name: ""
renewBefore: 360h</pre>
</div>
            </td>
            <td>A cert-manager Certificate for the FuseScope Service names, in `RELEASE-fusescope-ingest-tls`, instead of `existingSecret`. The issuer must set `ca.crt` (a CA or self-signed issuer) unless `caKey` is empty.</td>
        </tr>
        <tr>
            <td id="signoz--ingestPolicy--tls--clientCA"><a href="./values.yaml#L1044">signoz.ingestPolicy.tls.clientCA</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">existingSecret: ""
secretKey: ca.crt</pre>
</div>
            </td>
            <td>Secret and key of a CA collectors must present a client certificate from (mutual TLS); unset, none is asked for.</td>
        </tr>
    </tbody>
</table>
<h3>SigNoz Retention</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="signoz--retention--default--logs"><a href="./values.yaml#L1054">signoz.retention.default.logs</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Default logs retention in days. Empty keeps the schema default.</td>
        </tr>
        <tr>
            <td id="signoz--retention--default--traces"><a href="./values.yaml#L1057">signoz.retention.default.traces</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Default traces retention in days. Empty keeps the schema default.</td>
        </tr>
        <tr>
            <td id="signoz--retention--default--metrics"><a href="./values.yaml#L1060">signoz.retention.default.metrics</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Default metrics retention in days. Empty keeps the schema default.</td>
        </tr>
    </tbody>
</table>
<h3>Telemetry Store Migrator</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="telemetryStoreMigrator"><a href="./values.yaml#L1115">telemetryStoreMigrator</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Default values for the Telemetry Store Migrator.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--enabled"><a href="./values.yaml#L1119">telemetryStoreMigrator.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Enable the Telemetry Store Migrator component.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--migrator"><a href="./values.yaml#L1126">telemetryStoreMigrator.migrator</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">fusescope-schema</pre>
</div>
            </td>
            <td>Which migrator runs: `fusescope-schema`, the FuseScope schema migrator, a second binary of the FuseScope collector image (collector ADR 0010), or `fork`, the earlier collector's (`otelCollector.image`). Only the one chosen is rendered. fusescope-schema migrates only the replicated schema: `enableReplication: false` fails.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--image"><a href="./values.yaml#L1130">telemetryStoreMigrator.image</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">digest: sha256:9951f2479ac6e5150b116cd856569aaae6ed921e9b951f0fd9c93160e7311077
pullPolicy: IfNotPresent
registry: ghcr.io
repository: fuseone-io/fusescope-collector
tag: 0.4.1</pre>
</div>
            </td>
            <td>fusescope-schema's image, the signed FuseScope collector release 0.4.1 pinned by digest, for the Job and the collectors' init containers.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--backoffLimit"><a href="./values.yaml#L1141">telemetryStoreMigrator.backoffLimit</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">10</pre>
</div>
            </td>
            <td>How many times fusescope-schema's Job retries a connection or lease error (exit 2), as while ClickHouse starts on a fresh install. With Kubernetes' backoff, capped at 6 minutes, 10 retries span about 35 minutes. A refusal (1) or an interrupted migration (4) fails the Job at once.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--runId"><a href="./values.yaml#L1147">telemetryStoreMigrator.runId</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Any new value runs fusescope-schema's Job again with nothing else changed, as after it failed once its cause is fixed: the Job is named by a hash of its spec and this. An upgrade that changes neither leaves the Job alone, finished or running.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--podSecurityContext"><a href="./values.yaml#L1150">telemetryStoreMigrator.podSecurityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">fsGroup: 65532
runAsGroup: 65532
runAsNonRoot: true
runAsUser: 65532
seccompProfile:
    type: RuntimeDefault</pre>
</div>
            </td>
            <td>fusescope-schema's pod security context.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--securityContext"><a href="./values.yaml#L1160">telemetryStoreMigrator.securityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">allowPrivilegeEscalation: false
capabilities:
    drop:
        - ALL
readOnlyRootFilesystem: true</pre>
</div>
            </td>
            <td>fusescope-schema's container security context, also the collectors' init container's.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--name"><a href="./values.yaml#L1169">telemetryStoreMigrator.name</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">signoz-telemetrystore-migrator</pre>
</div>
            </td>
            <td>The name of the Telemetry Store Migrator component.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--annotations"><a href="./values.yaml#L1173">telemetryStoreMigrator.annotations</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Annotations for the Telemetry Store Migrator job.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--upgradeHelmHooks"><a href="./values.yaml#L1178">telemetryStoreMigrator.upgradeHelmHooks</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Enable Helm pre-upgrade hooks and ArgoCD Sync hooks. For `migrator: fork` only: fusescope-schema's Job is renamed whenever its spec changes instead.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--enableReplication"><a href="./values.yaml#L1182">telemetryStoreMigrator.enableReplication</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Whether to enable replication for the Telemetry Store Migrator.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--timeout"><a href="./values.yaml#L1187">telemetryStoreMigrator.timeout</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">10m</pre>
</div>
            </td>
            <td>Timeout for the migration; with fusescope-schema, how long the collectors' init container waits for it (`check --wait`).</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--nodeSelector"><a href="./values.yaml#L1191">telemetryStoreMigrator.nodeSelector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Node selector for pod assignment.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--tolerations"><a href="./values.yaml#L1195">telemetryStoreMigrator.tolerations</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Tolerations for pod assignment.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--affinity"><a href="./values.yaml#L1199">telemetryStoreMigrator.affinity</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Affinity settings for pod assignment.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--topologySpreadConstraints"><a href="./values.yaml#L1203">telemetryStoreMigrator.topologySpreadConstraints</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Topology spread constraints for pod distribution.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--resources"><a href="./values.yaml#L1207">telemetryStoreMigrator.resources</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Resource requests and limits for all migrator containers.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--serviceAccount"><a href="./values.yaml#L1210">telemetryStoreMigrator.serviceAccount</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
create: true
name: null</pre>
</div>
            </td>
            <td>Service Account configuration for the Telemetry Store Migrator.</td>
        </tr>
    </tbody>
</table>
<h3>Otel Collector</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="otelCollector"><a href="./values.yaml#L1224">otelCollector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Default values for the OpenTelemetry Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--enabled"><a href="./values.yaml#L1232">otelCollector.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Install the earlier OpenTelemetry Collector (fusescope-otel-collector). Off by default: the FuseScope collector (`fusescopeCollector`) receives OTLP and writes ClickHouse instead, behind a Service with this collector's name and OTLP ports. To keep this collector, set it to `true` and `fusescopeCollector.otlp.enabled` to `false`. Its image still runs the schema migrations (`telemetryStoreMigrator`) whatever this is set to.</td>
        </tr>
        <tr>
            <td id="otelCollector--name"><a href="./values.yaml#L1236">otelCollector.name</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">otel-collector</pre>
</div>
            </td>
            <td>The name of the Otel Collector component.</td>
        </tr>
        <tr>
            <td id="otelCollector--image"><a href="./values.yaml#L1240">otelCollector.image</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Image configuration for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--imagePullSecrets"><a href="./values.yaml#L1257">otelCollector.imagePullSecrets</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Image pull secrets for the Otel Collector. This has higher precedence than the root level or global value.</td>
        </tr>
        <tr>
            <td id="otelCollector--strategy"><a href="./values.yaml#L1261">otelCollector.strategy</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">RollingUpdate</pre>
</div>
            </td>
            <td>Deployment strategy to use</td>
        </tr>
        <tr>
            <td id="otelCollector--command"><a href="./values.yaml#L1264">otelCollector.command</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">extraArgs: null
name: /fusescope-otel-collector</pre>
</div>
            </td>
            <td>Configuration for the Otel Collector executable.</td>
        </tr>
        <tr>
            <td id="otelCollector--configMap"><a href="./values.yaml#L1272">otelCollector.configMap</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">create: true</pre>
</div>
            </td>
            <td>ConfigMap settings.</td>
        </tr>
        <tr>
            <td id="otelCollector--serviceAccount"><a href="./values.yaml#L1278">otelCollector.serviceAccount</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
create: true
name: null</pre>
</div>
            </td>
            <td>Service Account configuration for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--annotations"><a href="./values.yaml#L1306">otelCollector.annotations</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Annotations for the Otel Collector Deployment.</td>
        </tr>
        <tr>
            <td id="otelCollector--podAnnotations"><a href="./values.yaml#L1310">otelCollector.podAnnotations</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Annotations for the Otel Collector pod(s).</td>
        </tr>
        <tr>
            <td id="otelCollector--podLabels"><a href="./values.yaml#L1316">otelCollector.podLabels</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Labels for the Otel Collector pod(s).</td>
        </tr>
        <tr>
            <td id="otelCollector--additionalEnvs"><a href="./values.yaml#L1320">otelCollector.additionalEnvs</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Additional environment variables for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--lowCardinalityExceptionGrouping"><a href="./values.yaml#L1326">otelCollector.lowCardinalityExceptionGrouping</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Whether to enable grouping of exceptions with the same name but different stack traces. This is a tradeoff between cardinality and accuracy.</td>
        </tr>
        <tr>
            <td id="otelCollector--minReadySeconds"><a href="./values.yaml#L1330">otelCollector.minReadySeconds</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">5</pre>
</div>
            </td>
            <td>Minimum number of seconds for a new pod to be ready.</td>
        </tr>
        <tr>
            <td id="otelCollector--progressDeadlineSeconds"><a href="./values.yaml#L1334">otelCollector.progressDeadlineSeconds</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">600</pre>
</div>
            </td>
            <td>Maximum time in seconds for a deployment to make progress before it is considered failed.</td>
        </tr>
        <tr>
            <td id="otelCollector--replicaCount"><a href="./values.yaml#L1338">otelCollector.replicaCount</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">1</pre>
</div>
            </td>
            <td>The number of pod replicas for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--clusterRole"><a href="./values.yaml#L1342">otelCollector.clusterRole</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>RBAC ClusterRole configuration for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--livenessProbe"><a href="./values.yaml#L1585">otelCollector.livenessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Liveness probe configuration. ref: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-probes/#configure-probes</td>
        </tr>
        <tr>
            <td id="otelCollector--readinessProbe"><a href="./values.yaml#L1597">otelCollector.readinessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Readiness probe configuration.</td>
        </tr>
        <tr>
            <td id="otelCollector--customLivenessProbe"><a href="./values.yaml#L1609">otelCollector.customLivenessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Custom liveness probe to override the default.</td>
        </tr>
        <tr>
            <td id="otelCollector--customReadinessProbe"><a href="./values.yaml#L1613">otelCollector.customReadinessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Custom readiness probe to override the default.</td>
        </tr>
        <tr>
            <td id="otelCollector--extraVolumeMounts"><a href="./values.yaml#L1617">otelCollector.extraVolumeMounts</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Extra volume mounts for the Otel Collector pod.</td>
        </tr>
        <tr>
            <td id="otelCollector--extraVolumes"><a href="./values.yaml#L1621">otelCollector.extraVolumes</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Extra volumes for the Otel Collector pod.</td>
        </tr>
        <tr>
            <td id="otelCollector--resources"><a href="./values.yaml#L1658">otelCollector.resources</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Resource requests and limits. Ref: http://kubernetes.io/docs/user-guide/compute-resources/</td>
        </tr>
        <tr>
            <td id="otelCollector--priorityClassName"><a href="./values.yaml#L1669">otelCollector.priorityClassName</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Priority class for the Otel Collector pods.</td>
        </tr>
        <tr>
            <td id="otelCollector--nodeSelector"><a href="./values.yaml#L1673">otelCollector.nodeSelector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Node selector for pod assignment.</td>
        </tr>
        <tr>
            <td id="otelCollector--tolerations"><a href="./values.yaml#L1677">otelCollector.tolerations</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Tolerations for pod assignment.</td>
        </tr>
        <tr>
            <td id="otelCollector--affinity"><a href="./values.yaml#L1681">otelCollector.affinity</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Affinity settings for pod assignment.</td>
        </tr>
        <tr>
            <td id="otelCollector--topologySpreadConstraints"><a href="./values.yaml#L1685">otelCollector.topologySpreadConstraints</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Topology spread constraints for pod distribution.</td>
        </tr>
        <tr>
            <td id="otelCollector--podSecurityContext"><a href="./values.yaml#L1695">otelCollector.podSecurityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Pod-level security context.</td>
        </tr>
        <tr>
            <td id="otelCollector--securityContext"><a href="./values.yaml#L1701">otelCollector.securityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Container-level security context.</td>
        </tr>
        <tr>
            <td id="otelCollector--autoscaling"><a href="./values.yaml#L1712">otelCollector.autoscaling</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Autoscaling configuration (HPA).</td>
        </tr>
        <tr>
            <td id="otelCollector--autoscaling--keda"><a href="./values.yaml#L1749">otelCollector.autoscaling.keda</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: null
cooldownPeriod: "300"
enabled: false
maxReplicaCount: "5"
minReplicaCount: "1"
pollingInterval: "30"
triggers: []</pre>
</div>
            </td>
            <td>KEDA-based autoscaling configuration.</td>
        </tr>
    </tbody>
</table>
<h3>Otel Collector Networking</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="otelCollector--service"><a href="./values.yaml#L1290">otelCollector.service</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
labels: {}
loadBalancerSourceRanges: []
type: ClusterIP</pre>
</div>
            </td>
            <td>Service configuration for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--ingress"><a href="./values.yaml#L1624">otelCollector.ingress</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
className: ""
enabled: false
hosts:
    - host: otelcollector.domain.com
      paths:
        - path: /
          pathType: ImplementationSpecific
          port: 4318
tls: []</pre>
</div>
            </td>
            <td>Ingress configuration for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--ingress--hosts"><a href="./values.yaml#L1642">otelCollector.ingress.hosts</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Hostname and path configurations for the ingress.</td>
        </tr>
    </tbody>
</table>
<h3>Otel Collector Ports</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="otelCollector--ports"><a href="./values.yaml#L1382">otelCollector.ports</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Port configurations for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--ports--otlp"><a href="./values.yaml#L1385">otelCollector.ports.otlp</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">containerPort: 4317
enabled: true
nodePort: ""
protocol: TCP
servicePort: 4317</pre>
</div>
            </td>
            <td>OTLP gRPC port configuration.</td>
        </tr>
        <tr>
            <td id="otelCollector--ports--otlp-http"><a href="./values.yaml#L1403">otelCollector.ports.otlp-http</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">containerPort: 4318
enabled: true
nodePort: ""
protocol: TCP
servicePort: 4318</pre>
</div>
            </td>
            <td>OTLP HTTP port configuration.</td>
        </tr>
        <tr>
            <td id="otelCollector--ports--jaeger-compact"><a href="./values.yaml#L1421">otelCollector.ports.jaeger-compact</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">containerPort: 6831
enabled: false
nodePort: ""
protocol: UDP
servicePort: 6831</pre>
</div>
            </td>
            <td>Jaeger Compact port configuration.</td>
        </tr>
        <tr>
            <td id="otelCollector--ports--jaeger-thrift"><a href="./values.yaml#L1439">otelCollector.ports.jaeger-thrift</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">containerPort: 14268
enabled: true
nodePort: ""
protocol: TCP
servicePort: 14268</pre>
</div>
            </td>
            <td>Jaeger Thrift port configuration.</td>
        </tr>
        <tr>
            <td id="otelCollector--ports--jaeger-grpc"><a href="./values.yaml#L1457">otelCollector.ports.jaeger-grpc</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">containerPort: 14250
enabled: true
nodePort: ""
protocol: TCP
servicePort: 14250</pre>
</div>
            </td>
            <td>Jaeger gRPC port configuration.</td>
        </tr>
        <tr>
            <td id="otelCollector--ports--zipkin"><a href="./values.yaml#L1475">otelCollector.ports.zipkin</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">containerPort: 9411
enabled: false
nodePort: ""
protocol: TCP
servicePort: 9411</pre>
</div>
            </td>
            <td>Zipkin port configuration.</td>
        </tr>
        <tr>
            <td id="otelCollector--ports--metrics"><a href="./values.yaml#L1493">otelCollector.ports.metrics</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">containerPort: 8888
enabled: true
nodePort: ""
protocol: TCP
servicePort: 8888</pre>
</div>
            </td>
            <td>Internal metrics port configuration.</td>
        </tr>
        <tr>
            <td id="otelCollector--ports--zpages"><a href="./values.yaml#L1511">otelCollector.ports.zpages</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">containerPort: 55679
enabled: false
nodePort: ""
protocol: TCP
servicePort: 55679</pre>
</div>
            </td>
            <td>ZPages port configuration.</td>
        </tr>
        <tr>
            <td id="otelCollector--ports--pprof"><a href="./values.yaml#L1529">otelCollector.ports.pprof</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">containerPort: 1777
enabled: false
nodePort: ""
protocol: TCP
servicePort: 1777</pre>
</div>
            </td>
            <td>pprof port configuration.</td>
        </tr>
        <tr>
            <td id="otelCollector--ports--logsheroku"><a href="./values.yaml#L1547">otelCollector.ports.logsheroku</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">containerPort: 8081
enabled: true
nodePort: ""
protocol: TCP
servicePort: 8081</pre>
</div>
            </td>
            <td>Heroku logs port configuration.</td>
        </tr>
        <tr>
            <td id="otelCollector--ports--logsjson"><a href="./values.yaml#L1565">otelCollector.ports.logsjson</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">containerPort: 8082
enabled: true
nodePort: ""
protocol: TCP
servicePort: 8082</pre>
</div>
            </td>
            <td>JSON logs port configuration.</td>
        </tr>
    </tbody>
</table>
<h3>Otel Collector Configuration</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="otelCollector--config"><a href="./values.yaml#L1774">otelCollector.config</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Main configuration for the OpenTelemetry Collector pipelines.</td>
        </tr>
    </tbody>
</table>
<h3>MCP Server</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="mcpServer--enabled"><a href="./values.yaml#L1902">mcpServer.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Install the FuseScope MCP server in HTTP mode.</td>
        </tr>
        <tr>
            <td id="mcpServer--replicaCount"><a href="./values.yaml#L1905">mcpServer.replicaCount</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">1</pre>
</div>
            </td>
            <td>Number of replicas. The server is stateless.</td>
        </tr>
        <tr>
            <td id="mcpServer--image"><a href="./values.yaml#L1908">mcpServer.image</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">digest: ""
pullPolicy: IfNotPresent
registry: ghcr.io
repository: fuseone-io/fusescope-mcp-server
tag: 0.18.1</pre>
</div>
            </td>
            <td>MCP server image. Set `digest` to pin it; it takes precedence over `tag`.</td>
        </tr>
        <tr>
            <td id="mcpServer--imagePullSecrets"><a href="./values.yaml#L1916">mcpServer.imagePullSecrets</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Image pull secrets. Overrides the root and global values.</td>
        </tr>
        <tr>
            <td id="mcpServer--fusescopeUrl"><a href="./values.yaml#L1921">mcpServer.fusescopeUrl</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">http://RELEASE-fusescope:8080, the backend Service</pre>
</div>
            </td>
            <td>FuseScope URL the server calls, and the only one it accepts in a client's `X-SigNoz-URL` header (`FUSESCOPE_INSTANCE_URL_ALLOWLIST`).</td>
        </tr>
        <tr>
            <td id="mcpServer--apiKey--existingSecret"><a href="./values.yaml#L1928">mcpServer.apiKey.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Secret holding a key the server uses for clients that send none. WARNING: anyone who can reach the endpoint then acts with this key's role. Use a Viewer service account, and keep the endpoint private (NetworkPolicy, no public ingress).</td>
        </tr>
        <tr>
            <td id="mcpServer--apiKey--secretKey"><a href="./values.yaml#L1931">mcpServer.apiKey.secretKey</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">api-key</pre>
</div>
            </td>
            <td>Key in `existingSecret` holding the API key.</td>
        </tr>
        <tr>
            <td id="mcpServer--docsRefreshInterval"><a href="./values.yaml#L1936">mcpServer.docsRefreshInterval</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">6h</pre>
</div>
            </td>
            <td>Incremental refresh of the docs index from docs.fusescope.fuseone.io (`FUSESCOPE_DOCS_REFRESH_INTERVAL`); `"0"` turns it off.</td>
        </tr>
        <tr>
            <td id="mcpServer--docsFullRefreshInterval"><a href="./values.yaml#L1942">mcpServer.docsFullRefreshInterval</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">24h</pre>
</div>
            </td>
            <td>Full rebuild of the docs index (`FUSESCOPE_DOCS_FULL_REFRESH_INTERVAL`); `"0"` turns it off. With both off the server serves the docs bundled with its release and needs no egress to the internet.</td>
        </tr>
        <tr>
            <td id="mcpServer--logLevel"><a href="./values.yaml#L1945">mcpServer.logLevel</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">info</pre>
</div>
            </td>
            <td>`debug`, `info`, `warn` or `error`.</td>
        </tr>
        <tr>
            <td id="mcpServer--extraEnv"><a href="./values.yaml#L1949">mcpServer.extraEnv</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Extra environment variables, e.g. `OTEL_EXPORTER_OTLP_ENDPOINT`, or `FUSESCOPE_CUSTOM_HEADERS` from a Secret.</td>
        </tr>
        <tr>
            <td id="mcpServer--serviceAccount"><a href="./values.yaml#L1952">mcpServer.serviceAccount</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
create: true
name: ""</pre>
</div>
            </td>
            <td>Service account. No API token is mounted.</td>
        </tr>
        <tr>
            <td id="mcpServer--service"><a href="./values.yaml#L1958">mcpServer.service</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
port: 8000
type: ClusterIP</pre>
</div>
            </td>
            <td>Service for the MCP endpoint.</td>
        </tr>
        <tr>
            <td id="mcpServer--ingress"><a href="./values.yaml#L1965">mcpServer.ingress</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
className: ""
enabled: false
hosts: []
path: /mcp
pathType: Prefix
tls: []</pre>
</div>
            </td>
            <td>Ingress for `/mcp`. Without `hosts`, it uses the hosts, TLS and class of `signoz.ingress`. Its annotations are not inherited: don't repeat a cert-manager issuer there.</td>
        </tr>
        <tr>
            <td id="mcpServer--networkPolicy"><a href="./values.yaml#L1977">mcpServer.networkPolicy</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">docsEgress:
    cidr: 0.0.0.0/0
    except:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
enabled: false
extraEgress: []
ingressFrom:
    - podSelector: {}
    - namespaceSelector:
        matchLabels:
            kubernetes.io/metadata.name: ingress-nginx</pre>
</div>
            </td>
            <td>NetworkPolicy. Ingress on the MCP port from `ingressFrom`; egress to the backend, DNS, HTTPS to `docsEgress` while a docs refresh is on, and `extraEgress`. The default `ingressFrom` admits this namespace and the `ingress-nginx` namespace.</td>
        </tr>
        <tr>
            <td id="mcpServer--resources"><a href="./values.yaml#L1993">mcpServer.resources</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">limits:
    memory: 512Mi
requests:
    cpu: 50m
    memory: 256Mi</pre>
</div>
            </td>
            <td>Resources. Building the docs index takes about 130 MiB above the baseline.</td>
        </tr>
        <tr>
            <td id="mcpServer--podSecurityContext"><a href="./values.yaml#L2001">mcpServer.podSecurityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">fsGroup: 1001
runAsGroup: 1001
runAsNonRoot: true
runAsUser: 1001
seccompProfile:
    type: RuntimeDefault</pre>
</div>
            </td>
            <td>Pod security context. The image runs as uid 1001.</td>
        </tr>
        <tr>
            <td id="mcpServer--securityContext"><a href="./values.yaml#L2010">mcpServer.securityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">allowPrivilegeEscalation: false
capabilities:
    drop:
        - ALL
readOnlyRootFilesystem: true</pre>
</div>
            </td>
            <td>Container security context.</td>
        </tr>
        <tr>
            <td id="mcpServer--livenessProbe"><a href="./values.yaml#L2018">mcpServer.livenessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">failureThreshold: 6
initialDelaySeconds: 5
periodSeconds: 10
timeoutSeconds: 5</pre>
</div>
            </td>
            <td>Liveness probe timing on `/livez`.</td>
        </tr>
        <tr>
            <td id="mcpServer--readinessProbe"><a href="./values.yaml#L2025">mcpServer.readinessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">failureThreshold: 6
initialDelaySeconds: 5
periodSeconds: 10
timeoutSeconds: 5</pre>
</div>
            </td>
            <td>Readiness probe timing on `/readyz`, ready once the docs index is built.</td>
        </tr>
        <tr>
            <td id="mcpServer--podAnnotations"><a href="./values.yaml#L2032">mcpServer.podAnnotations</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Pod annotations.</td>
        </tr>
        <tr>
            <td id="mcpServer--priorityClassName"><a href="./values.yaml#L2035">mcpServer.priorityClassName</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Priority class.</td>
        </tr>
        <tr>
            <td id="mcpServer--nodeSelector"><a href="./values.yaml#L2038">mcpServer.nodeSelector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Node selector.</td>
        </tr>
        <tr>
            <td id="mcpServer--tolerations"><a href="./values.yaml#L2041">mcpServer.tolerations</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Tolerations.</td>
        </tr>
        <tr>
            <td id="mcpServer--affinity"><a href="./values.yaml#L2044">mcpServer.affinity</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Affinity.</td>
        </tr>
        <tr>
            <td id="mcpServer--topologySpreadConstraints"><a href="./values.yaml#L2047">mcpServer.topologySpreadConstraints</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Topology spread constraints.</td>
        </tr>
    </tbody>
</table>
<h3>FuseScope Collector</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="fusescopeCollector--enabled"><a href="./values.yaml#L2055">fusescopeCollector.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Install the FuseScope collector, the chart's OTLP collector: it receives OTLP (`otlp`), and Real User Monitoring when `rum.enabled`, and writes ClickHouse directly. FuseScope manages its log pipelines, span mapping and LLM pricing over OpAMP.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--replicaCount"><a href="./values.yaml#L2060">fusescopeCollector.replicaCount</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">1</pre>
</div>
            </td>
            <td>Number of replicas, unless `autoscaling.enabled`. Each registers with FuseScope as its own agent; with RUM, each holds its own copy of the policy and reports its own counts, and rate limits apply per replica.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--image"><a href="./values.yaml#L2065">fusescopeCollector.image</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">digest: sha256:3856f022c2ac27369c3bb1224b8945940bd7d6f6a30fce0f59734584cfc4374b
pullPolicy: IfNotPresent
registry: ghcr.io
repository: fuseone-io/fusescope-collector
tag: 0.3.1</pre>
</div>
            </td>
            <td>Collector image, by `tag` and `digest`: with both, the image is `<tag>@<digest>` and the digest is what is pulled. The default is the signed 0.3.1 multi-arch index.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--imagePullSecrets"><a href="./values.yaml#L2073">fusescopeCollector.imagePullSecrets</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Image pull secrets. Overrides the root and global values.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--otlp--enabled"><a href="./values.yaml#L2080">fusescopeCollector.otlp.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Receive OTLP over gRPC and HTTP, on this collector's Service and, while `otelCollector.enabled` is false, on a Service named and numbered like the earlier collector's (`RELEASE-fusescope-otel-collector`, ports `otlp` and `otlp-http` of `otelCollector.ports`), so agents, SDKs and `otelCollector.ingress` keep their endpoint.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--otlp--grpcPort"><a href="./values.yaml#L2083">fusescopeCollector.otlp.grpcPort</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">4317</pre>
</div>
            </td>
            <td>Port of the OTLP/gRPC receiver.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--otlp--httpPort"><a href="./values.yaml#L2086">fusescopeCollector.otlp.httpPort</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">4318</pre>
</div>
            </td>
            <td>Port of the OTLP/HTTP receiver.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--ingestToken--existingSecret"><a href="./values.yaml#L2092">fusescopeCollector.ingestToken.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">signoz.ingestPolicy.tokens.existingSecret</pre>
</div>
            </td>
            <td>Secret holding the one token, 32 to 256 characters, the collector presents to FuseScope with `rum.enabled`.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--ingestToken--secretKey"><a href="./values.yaml#L2096">fusescopeCollector.ingestToken.secretKey</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">signoz.ingestPolicy.tokens.secretKey</pre>
</div>
            </td>
            <td>Key in `existingSecret` holding the token.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--opamp--endpoint"><a href="./values.yaml#L2104">fusescopeCollector.opamp.endpoint</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">wss://RELEASE-fusescope:4321/v1/opamp with rum.enabled (signoz.ingestPolicy.port), else ws://RELEASE-fusescope:4320/v1/opamp (signoz.service.opampPort)</pre>
</div>
            </td>
            <td>OpAMP endpoint of FuseScope. With `rum.enabled`, its TLS listener, where the ingest policy is served; without, the in-cluster listener, plaintext (`tls.insecure`) since FuseScope serves no TLS there yet. A `wss://` endpoint is always reached with TLS 1.3.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--opamp--clientCertSecret"><a href="./values.yaml#L2108">fusescopeCollector.opamp.clientCertSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>`kubernetes.io/tls` Secret with the client certificate the collector presents when `signoz.ingestPolicy.tls.clientCA` is set.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--enabled"><a href="./values.yaml#L2116">fusescopeCollector.rum.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Serve Real User Monitoring: `/rum/v1/traces` and `/rum/v1/logs` on a TLS 1.3 listener, with the ingest policy FuseScope sends over OpAMP with TLS (`signoz.ingestPolicy`). Needs a FuseScope release with the ingest policy listener (fuseone-io/fusescope#314), `signoz.ingestPolicy.tokens` and both TLS certificates. Before chart 0.161.0 RUM came with `fusescopeCollector.enabled`; such installs must now set this.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--tlsMinVersion"><a href="./values.yaml#L2121">fusescopeCollector.rum.tlsMinVersion</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">"1.3"</pre>
</div>
            </td>
            <td>RUM TLS minimum, `"1.3"` or `"1.2"`. `"1.2"` opts in for stock Android 6-9 (API 23-28), with ECDHE AEAD suites only (collector ADR 0009); the public proxy in front must accept TLS 1.2 on the RUM endpoint too.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--port"><a href="./values.yaml#L2124">fusescopeCollector.rum.port</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">4319</pre>
</div>
            </td>
            <td>Port of the RUM listener.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--tls--existingSecret"><a href="./values.yaml#L2130">fusescopeCollector.rum.tls.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>`kubernetes.io/tls` Secret with the RUM listener's `tls.crt` and `tls.key`. Behind the ingress it is the certificate between the ingress controller and the collector, so a cluster-internal one does.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--tls--certManager"><a href="./values.yaml#L2134">fusescopeCollector.rum.tls.certManager</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">duration: 2160h
enabled: false
issuerRef:
    group: cert-manager.io
    kind: Issuer
    name: ""
renewBefore: 360h</pre>
</div>
            </td>
            <td>A cert-manager Certificate for the collector Service names, in `RELEASE-fusescope-collector-rum-tls`, instead of `existingSecret`.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--trustedProxies"><a href="./values.yaml#L2147">fusescopeCollector.rum.trustedProxies</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">10.0.0.0/8, 172.16.0.0/12 and 192.168.0.0/16 with the ingress on, else none</pre>
</div>
            </td>
            <td>CIDRs whose `X-Forwarded-For` is read for the per-client rate limit, walked from the right past the trusted addresses. Behind an ingress or load balancer it must cover them, or every browser shares one limit.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--maxBodySize"><a href="./values.yaml#L2151">fusescopeCollector.rum.maxBodySize</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">4.194304e+06</pre>
</div>
            </td>
            <td>Largest accepted request body in bytes, before and after gzip decoding.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--rateLimit--key--rate"><a href="./values.yaml#L2157">fusescopeCollector.rum.rateLimit.key.rate</a></td>
            <td>float</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">500</pre>
</div>
            </td>
            <td>Requests per second shared by every client of one key, per replica, when the policy gives the key no limit.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--rateLimit--key--burst"><a href="./values.yaml#L2160">fusescopeCollector.rum.rateLimit.key.burst</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">1000</pre>
</div>
            </td>
            <td>Burst size of the per-key limit.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--rateLimit--client--rate"><a href="./values.yaml#L2165">fusescopeCollector.rum.rateLimit.client.rate</a></td>
            <td>float</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">20</pre>
</div>
            </td>
            <td>Requests per second per key and client IP, per replica.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--rateLimit--client--burst"><a href="./values.yaml#L2168">fusescopeCollector.rum.rateLimit.client.burst</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">60</pre>
</div>
            </td>
            <td>Burst size of the per-client limit.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--maxStaleness"><a href="./values.yaml#L2173">fusescopeCollector.rum.maxStaleness</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Refuse RUM requests, and report not ready, once the policy held was last received longer ago than this, e.g. `1h`. Empty, a policy held keeps working through a FuseScope outage.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--agentListener--enabled"><a href="./values.yaml#L2180">fusescopeCollector.agentListener.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Receive OTLP/gRPC from the FuseScope agents (`fusescopeAgent`) on a listener of its own: TLS 1.3, a client certificate the client CA signed, and the agents' token, all required. The OTLP ports above stay as they are, without TLS, for SDKs inside the cluster.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--agentListener--port"><a href="./values.yaml#L2184">fusescopeCollector.agentListener.port</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">4322</pre>
</div>
            </td>
            <td>Port of the agents' listener, on the pods and the collector's Service. Not 4319, which RUM uses.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--agentListener--tls--existingSecret"><a href="./values.yaml#L2190">fusescopeCollector.agentListener.tls.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>`kubernetes.io/tls` Secret with the listener's `tls.crt` and `tls.key`, for the collector Service names. Its `ca.crt`, when set, is what the agents verify it with by default (`fusescopeAgent.gateway.ca`).</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--agentListener--tls--certManager"><a href="./values.yaml#L2195">fusescopeCollector.agentListener.tls.certManager</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">duration: 2160h
enabled: false
issuerRef:
    group: cert-manager.io
    kind: Issuer
    name: ""
renewBefore: 360h</pre>
</div>
            </td>
            <td>A cert-manager Certificate for the collector Service names, in `RELEASE-fusescope-collector-agents-tls`, instead of `existingSecret`. Renewed certificates reach the pods without a restart.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--agentListener--clientCA--existingSecret"><a href="./values.yaml#L2210">fusescopeCollector.agentListener.clientCA.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">the agents' certificate Secret</pre>
</div>
            </td>
            <td>Secret holding the CA bundle that agent certificates must chain to. Empty, the `ca.crt` of the agents' own certificate Secret (`fusescopeAgent.tls`). To replace the CA, put both CAs in one bundle here first (README, Agents).</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--agentListener--clientCA--key"><a href="./values.yaml#L2213">fusescopeCollector.agentListener.clientCA.key</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">ca.crt</pre>
</div>
            </td>
            <td>Key in that Secret holding the bundle.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--agentListener--token--existingSecret"><a href="./values.yaml#L2219">fusescopeCollector.agentListener.token.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Secret holding the token the agents present and this listener requires, 32 to 256 characters. The agents and the collector read the same Secret; never put the token in values.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--agentListener--token--secretKey"><a href="./values.yaml#L2222">fusescopeCollector.agentListener.token.secretKey</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">token</pre>
</div>
            </td>
            <td>Key in `existingSecret` holding the token.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--agentListener--networkPolicy--enabled"><a href="./values.yaml#L2228">fusescopeCollector.agentListener.networkPolicy.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>A NetworkPolicy on the collector pods: the agents' port accepts only the agent pods of this release; the other ports keep accepting from anywhere, as without it. Needs a CNI that enforces NetworkPolicy.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--meter--enabled"><a href="./values.yaml#L2235">fusescopeCollector.meter.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Count the ingested spans, log records and data points, and the sizes of spans and log records, each hour, per service and ingestion key, into `signoz_meter` for Meter Explorer and Ingestion Settings (`fusescope_meter`, through its own `fusescope_clickhouse/meter` exporter). Derived data (span metrics, the collector's own telemetry) is not metered.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--attributesMetadata--enabled"><a href="./values.yaml#L2241">fusescopeCollector.attributesMetadata.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Record the distinct attribute sets of what is written into `signoz_metadata`, for the related values of filter suggestions. Bounded, and never delays or fails the data path.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--selfMetrics--enabled"><a href="./values.yaml#L2247">fusescopeCollector.selfMetrics.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Write the collector's own telemetry (receivers, processors, exporters, queues, memory) to ClickHouse as `otelcol_*` metrics. It is read from its listener on 127.0.0.1:8888, which is never exposed.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--selfMetrics--scrapeInterval"><a href="./values.yaml#L2250">fusescopeCollector.selfMetrics.scrapeInterval</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">60s</pre>
</div>
            </td>
            <td>How often the telemetry is read.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--serviceAccount"><a href="./values.yaml#L2253">fusescopeCollector.serviceAccount</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
create: true
name: ""</pre>
</div>
            </td>
            <td>Service account. No API token is mounted.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--service"><a href="./values.yaml#L2259">fusescopeCollector.service</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
type: ClusterIP</pre>
</div>
            </td>
            <td>Service for the OTLP and RUM listeners.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--ingress"><a href="./values.yaml#L2268">fusescopeCollector.ingress</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    nginx.ingress.kubernetes.io/proxy-body-size: 4m
className: ""
enabled: false
hosts: []
tls: []</pre>
</div>
            </td>
            <td>Ingress for RUM, with `rum.enabled`: `/rum/v1/traces` and `/rum/v1/logs`, `Exact`, so the browser SDK FuseScope serves at `/rum/v1/sdk/` stays on its ingress. It re-encrypts to the collector's TLS listener. Without `hosts`, it uses the hosts, TLS and class of `signoz.ingress`. Its annotations are not inherited; the defaults tell ingress-nginx the backend speaks HTTPS and raise its 1m body limit to `rum.maxBodySize`; another controller needs its own equivalents.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--storage"><a href="./values.yaml#L2281">fusescopeCollector.storage</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">sizeLimit: 64Mi</pre>
</div>
            </td>
            <td>Volume of the OpAMP state: the instance UID, the last applied configuration push and, with RUM, the cached ingest policy and the report sequence. An emptyDir keeps them across container restarts; on a new pod the collector registers as a new agent and, with RUM, waits for the policy before it is ready.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--resources"><a href="./values.yaml#L2287">fusescopeCollector.resources</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">limits:
    memory: 1Gi
requests:
    cpu: 200m
    memory: 512Mi</pre>
</div>
            </td>
            <td>Resources. `memory_limiter` refuses data above 80% of the memory limit, so senders retry instead of the pod being OOM-killed; size the limit for the batches in flight, about 10 s of ingest per replica, or scale out (`autoscaling`).</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--autoscaling"><a href="./values.yaml#L2297">fusescopeCollector.autoscaling</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">behavior: {}
enabled: false
maxReplicas: 5
minReplicas: 1
targetCPUUtilizationPercentage: 70
targetMemoryUtilizationPercentage: 80</pre>
</div>
            </td>
            <td>Horizontal Pod Autoscaler. When enabled, the Deployment leaves `replicas` to it. Memory utilization is of the request: keep its target below the `memory_limiter` threshold (80% of the limit).</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--podSecurityContext"><a href="./values.yaml#L2307">fusescopeCollector.podSecurityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">fsGroup: 65532
runAsGroup: 65532
runAsNonRoot: true
runAsUser: 65532
seccompProfile:
    type: RuntimeDefault</pre>
</div>
            </td>
            <td>Pod security context. The image is distroless and runs as uid 65532.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--securityContext"><a href="./values.yaml#L2316">fusescopeCollector.securityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">allowPrivilegeEscalation: false
capabilities:
    drop:
        - ALL
readOnlyRootFilesystem: true</pre>
</div>
            </td>
            <td>Container security context.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--livenessProbe"><a href="./values.yaml#L2324">fusescopeCollector.livenessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">failureThreshold: 6
initialDelaySeconds: 10
periodSeconds: 10
timeoutSeconds: 5</pre>
</div>
            </td>
            <td>Liveness probe timing, a TCP check of the health port.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--readinessProbe"><a href="./values.yaml#L2332">fusescopeCollector.readinessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">failureThreshold: 3
initialDelaySeconds: 5
periodSeconds: 5
timeoutSeconds: 5</pre>
</div>
            </td>
            <td>Readiness probe timing on the health status; with RUM, ready only while the collector holds a valid ingest policy.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--podAnnotations"><a href="./values.yaml#L2339">fusescopeCollector.podAnnotations</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Pod annotations.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--priorityClassName"><a href="./values.yaml#L2342">fusescopeCollector.priorityClassName</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Priority class.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--nodeSelector"><a href="./values.yaml#L2345">fusescopeCollector.nodeSelector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Node selector.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--tolerations"><a href="./values.yaml#L2348">fusescopeCollector.tolerations</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Tolerations.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--affinity"><a href="./values.yaml#L2351">fusescopeCollector.affinity</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Affinity.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--topologySpreadConstraints"><a href="./values.yaml#L2354">fusescopeCollector.topologySpreadConstraints</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Topology spread constraints.</td>
        </tr>
    </tbody>
</table>
<h3>FuseScope Agent</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="fusescopeAgent--enabled"><a href="./values.yaml#L2363">fusescopeAgent.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Run the FuseScope collector in agent mode, a DaemonSet: pod logs, host metrics and kubelet stats of each node, sent to the collector's agents' listener (`fusescopeCollector.agentListener`) over mTLS with TLS 1.3 and a token. It writes no storage and takes no OpAMP configuration. Needs `fusescopeCollector.agentListener.enabled`.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--image"><a href="./values.yaml#L2367">fusescopeAgent.image</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">fusescopeCollector.image</pre>
</div>
            </td>
            <td>Image. Empty fields take `fusescopeCollector.image`'s.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--gateway--endpoint"><a href="./values.yaml#L2378">fusescopeAgent.gateway.endpoint</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">RELEASE-fusescope-collector.NAMESPACE.svc:fusescopeCollector.agentListener.port</pre>
</div>
            </td>
            <td>Where the agents send, `host:port`. The name must be in the listener's certificate.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--gateway--ca--existingSecret"><a href="./values.yaml#L2384">fusescopeAgent.gateway.ca.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">the listener's certificate Secret</pre>
</div>
            </td>
            <td>Secret holding the CA bundle the agents verify the listener's certificate with. Empty, the listener's certificate Secret.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--gateway--ca--key"><a href="./values.yaml#L2387">fusescopeAgent.gateway.ca.key</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">ca.crt</pre>
</div>
            </td>
            <td>Key in that Secret holding the bundle.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--tls--existingSecret"><a href="./values.yaml#L2392">fusescopeAgent.tls.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>`kubernetes.io/tls` Secret with the client certificate and key every agent presents: one per cluster or agent pool, not one per pod.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--tls--certManager"><a href="./values.yaml#L2397">fusescopeAgent.tls.certManager</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">commonName: fusescope-agent
duration: 2160h
enabled: false
issuerRef:
    group: cert-manager.io
    kind: Issuer
    name: ""
renewBefore: 360h</pre>
</div>
            </td>
            <td>A cert-manager Certificate (client auth) in `RELEASE-fusescope-agent-tls`, instead of `existingSecret`. A CA issuer sets its `ca.crt`, which the listener verifies agents with by default.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--tls--certManager--commonName"><a href="./values.yaml#L2405">fusescopeAgent.tls.certManager.commonName</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">fusescope-agent</pre>
</div>
            </td>
            <td>Common name of the agents' certificate.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--podLogs--enabled"><a href="./values.yaml#L2412">fusescopeAgent.podLogs.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Read the node's pod logs (`/var/log/pods`), from their end on first start, keeping read offsets on the node (`statePath`). The agents' own logs are left out.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--hostMetrics--enabled"><a href="./values.yaml#L2417">fusescopeAgent.hostMetrics.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Node CPU, memory, load, filesystem and network metrics, from the host root mounted read-only.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--hostMetrics--collectionInterval"><a href="./values.yaml#L2420">fusescopeAgent.hostMetrics.collectionInterval</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">30s</pre>
</div>
            </td>
            <td>Scrape interval.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--kubeletStats--enabled"><a href="./values.yaml#L2425">fusescopeAgent.kubeletStats.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Node, pod and container metrics from the node's kubelet, authenticated with the agent's service account (`nodes/stats`).</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--kubeletStats--collectionInterval"><a href="./values.yaml#L2428">fusescopeAgent.kubeletStats.collectionInterval</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">30s</pre>
</div>
            </td>
            <td>Scrape interval.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--kubeletStats--insecureSkipVerify"><a href="./values.yaml#L2433">fusescopeAgent.kubeletStats.insecureSkipVerify</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Do not verify the kubelet's serving certificate. Only for clusters whose kubelets serve a self-signed one; the agent then trusts whatever answers on the node's port 10250.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--statePath"><a href="./values.yaml#L2437">fusescopeAgent.statePath</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">/var/lib/fusescope-agent</pre>
</div>
            </td>
            <td>Host directory for the log read offsets, so a restarted agent resumes where it stopped.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--serviceAccount"><a href="./values.yaml#L2441">fusescopeAgent.serviceAccount</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
create: true
name: ""</pre>
</div>
            </td>
            <td>Service account, with a ClusterRole to read pods, namespaces, nodes and replica sets (pod attributes) and `nodes/stats` (kubelet stats).</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--resources"><a href="./values.yaml#L2447">fusescopeAgent.resources</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">limits:
    memory: 512Mi
requests:
    cpu: 100m
    memory: 128Mi</pre>
</div>
            </td>
            <td>Resources.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--podSecurityContext"><a href="./values.yaml#L2457">fusescopeAgent.podSecurityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">runAsGroup: 0
runAsNonRoot: false
runAsUser: 0
seccompProfile:
    type: RuntimeDefault</pre>
</div>
            </td>
            <td>Pod security context. Root, to read pod logs, which the node keeps readable by root only; the root filesystem stays read-only and every capability is dropped.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--securityContext"><a href="./values.yaml#L2465">fusescopeAgent.securityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">allowPrivilegeEscalation: false
capabilities:
    drop:
        - ALL
readOnlyRootFilesystem: true</pre>
</div>
            </td>
            <td>Container security context.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--podAnnotations"><a href="./values.yaml#L2473">fusescopeAgent.podAnnotations</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Pod annotations.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--priorityClassName"><a href="./values.yaml#L2476">fusescopeAgent.priorityClassName</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Priority class.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--nodeSelector"><a href="./values.yaml#L2479">fusescopeAgent.nodeSelector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Node selector.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--tolerations"><a href="./values.yaml#L2482">fusescopeAgent.tolerations</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Tolerations. Add the control plane's to collect from it too.</td>
        </tr>
        <tr>
            <td id="fusescopeAgent--affinity"><a href="./values.yaml#L2485">fusescopeAgent.affinity</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Affinity.</td>
        </tr>
    </tbody>
</table>
<h3>Postgres</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="postgresql--enabled"><a href="./values.yaml#L2493">postgresql.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Enable or disable the PostgreSQL for signoz. For more details, check out the postgresql chart: https://github.com/SigNoz/charts/tree/main/charts/postgresql</td>
        </tr>
    </tbody>
</table>
<h3>FuseScope engine</h3>
<table>
    <thead>
        <th>Key</th>
        <th>Type</th>
        <th>Default</th>
        <th>Description</th>
    </thead>
    <tbody>
        <tr>
            <td id="engine--enabled"><a href="./values.yaml#L2502">engine.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Install the FuseScope engine, the Parquet storage and query layer that will replace ClickHouse. Experimental and under construction: leave it off. Its settings are the fusescope-engine chart's values under `engine`.</td>
        </tr>
    </tbody>
</table>

