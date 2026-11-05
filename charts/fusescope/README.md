
# FuseScope

![Version: 0.160.1](https://img.shields.io/badge/Version-0.160.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.159.0](https://img.shields.io/badge/AppVersion-0.159.0-informational?style=flat-square)

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

- Kubernetes 1.16+
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

### Real User Monitoring

The FuseScope collector (`fusescopeCollector`) receives RUM: browsers and apps send OTLP/HTTP to `POST /rum/v1/traces` and `POST /rum/v1/logs`, authenticated by the application's public key, and the collector writes ClickHouse directly. The chart no longer configures the FuseScope backend's own RUM gateway, which is being removed. The collector takes the RUM applications and keys from FuseScope as the ingest policy, over OpAMP with TLS 1.3 on a second FuseScope listener (`signoz.ingestPolicy`, port 4321), and reports what it accepted for the RUM setup screen. It needs a FuseScope release with that listener (fuseone-io/fusescope#314).

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
    tls:
      certManager:
        enabled: true
        issuerRef: {name: internal-ca}
  ingress:
    enabled: true                               # /rum/v1/traces and /rum/v1/logs on the signoz.ingress hosts and TLS
```

- **Token.** Create the Secret before installing, e.g. `kubectl create secret generic fusescope-ingest-tokens --from-literal=tokens=$(openssl rand -hex 32)`. FuseScope accepts any token in it and the collector presents the same one; to rotate, give the collector its own Secret (`fusescopeCollector.ingestToken`), add the new token to FuseScope's, switch the collector, then remove the old one. FuseScope reads the tokens at start.
- **Certificates.** Both listeners are TLS 1.3 only, with a certificate from a Secret (`existingSecret`, a `kubernetes.io/tls` Secret) or a cert-manager Certificate. The collector verifies FuseScope's against the Secret's `ca.crt`; set `signoz.ingestPolicy.tls.caKey: ""` for a certificate from a public CA. Renewals are picked up without a restart.
- **Readiness.** The collector is ready only while it holds a valid ingest policy, so RUM reaches it only once FuseScope has published one. Until then, and if FuseScope never does (no token, wrong certificate), the pod runs but stays out of the Service; its log says why.
- **Ingress.** The collector's Ingress re-encrypts to its TLS listener. The default annotations are ingress-nginx's (`backend-protocol: HTTPS`, `proxy-body-size: 4m`); set the equivalents for another controller. It takes only `/rum/v1/traces` and `/rum/v1/logs` (`Exact`), more specific than the FuseScope ingress's `/`, so both share a host and the browser SDK FuseScope serves at `/rum/v1/sdk/` stays on the FuseScope ingress.
- **CORS belongs to the collector.** It answers `OPTIONS` preflights from each application's allowed origins. The ingress must pass `OPTIONS` and the `Origin` header through and must not add CORS headers of its own: with ingress-nginx, don't set `nginx.ingress.kubernetes.io/enable-cors`.
- **Client IP.** The per-client rate limit (20 req/s, burst 60) keys on the client IP, taken from `X-Forwarded-For` only when the peer is in `fusescopeCollector.rum.trustedProxies`, walking the header from the right past trusted addresses. With the ingress on, the private ranges are trusted by default; keep the real client IP reaching the controller (e.g. `externalTrafficPolicy: Local` or PROXY protocol).

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
            <td id="externalClickhouse"><a href="./values.yaml#L729">externalClickhouse</a></td>
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
            <td id="signoz"><a href="./values.yaml#L775">signoz</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Default values for SigNoz.</td>
        </tr>
        <tr>
            <td id="signoz--name"><a href="./values.yaml#L779">signoz.name</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">signoz</pre>
</div>
            </td>
            <td>The name of the SigNoz component.</td>
        </tr>
        <tr>
            <td id="signoz--replicaCount"><a href="./values.yaml#L783">signoz.replicaCount</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">1</pre>
</div>
            </td>
            <td>The number of pod replicas for SigNoz.</td>
        </tr>
        <tr>
            <td id="signoz--image"><a href="./values.yaml#L786">signoz.image</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">pullPolicy: IfNotPresent
registry: ghcr.io
repository: fuseone-io/fusescope
tag: 0.159.0</pre>
</div>
            </td>
            <td>Image configuration for SigNoz.</td>
        </tr>
        <tr>
            <td id="signoz--imagePullSecrets"><a href="./values.yaml#L804">signoz.imagePullSecrets</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Image pull secrets for SigNoz. This has higher precedence than the root level or global value.</td>
        </tr>
        <tr>
            <td id="signoz--serviceAccount"><a href="./values.yaml#L807">signoz.serviceAccount</a></td>
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
            <td id="signoz--annotations"><a href="./values.yaml#L851">signoz.annotations</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Annotations for the SigNoz pod.</td>
        </tr>
        <tr>
            <td id="signoz--config"><a href="./values.yaml#L858">signoz.config</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>FuseScope configuration file (see conf/example.yaml in fuseone-io/fusescope), rendered into a ConfigMap and passed with --config. Use it for settings that do not fit environment variables, e.g. SSO domains under `authdomain.domains`. Reference secrets as ${NAME} and provide them through `signoz.env`.</td>
        </tr>
        <tr>
            <td id="signoz--additionalArgs"><a href="./values.yaml#L862">signoz.additionalArgs</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Additional command-line arguments for SigNoz.</td>
        </tr>
        <tr>
            <td id="signoz--env"><a href="./values.yaml#L886">signoz.env</a></td>
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
            <td id="signoz--podSecurityContext"><a href="./values.yaml#L903">signoz.podSecurityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Pod-level security context.</td>
        </tr>
        <tr>
            <td id="signoz--podAnnotations"><a href="./values.yaml#L909">signoz.podAnnotations</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Annotations for the SigNoz pod.</td>
        </tr>
        <tr>
            <td id="signoz--securityContext"><a href="./values.yaml#L913">signoz.securityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Container-level security context.</td>
        </tr>
        <tr>
            <td id="signoz--additionalVolumeMounts"><a href="./values.yaml#L924">signoz.additionalVolumeMounts</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Additional volume mounts for the SigNoz container.</td>
        </tr>
        <tr>
            <td id="signoz--additionalVolumes"><a href="./values.yaml#L928">signoz.additionalVolumes</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Additional volumes for the SigNoz pod.</td>
        </tr>
        <tr>
            <td id="signoz--livenessProbe"><a href="./values.yaml#L932">signoz.livenessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Liveness probe configuration.</td>
        </tr>
        <tr>
            <td id="signoz--readinessProbe"><a href="./values.yaml#L944">signoz.readinessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Readiness probe configuration.</td>
        </tr>
        <tr>
            <td id="signoz--customLivenessProbe"><a href="./values.yaml#L956">signoz.customLivenessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Custom liveness probe to override the default.</td>
        </tr>
        <tr>
            <td id="signoz--customReadinessProbe"><a href="./values.yaml#L960">signoz.customReadinessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Custom readiness probe to override the default.</td>
        </tr>
        <tr>
            <td id="signoz--resources"><a href="./values.yaml#L1062">signoz.resources</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Resource requests and limits. Ref: http://kubernetes.io/docs/user-guide/compute-resources/</td>
        </tr>
        <tr>
            <td id="signoz--priorityClassName"><a href="./values.yaml#L1073">signoz.priorityClassName</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Priority class for the SigNoz pods.</td>
        </tr>
        <tr>
            <td id="signoz--nodeSelector"><a href="./values.yaml#L1077">signoz.nodeSelector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Node selector for pod assignment.</td>
        </tr>
        <tr>
            <td id="signoz--tolerations"><a href="./values.yaml#L1081">signoz.tolerations</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Tolerations for pod assignment.</td>
        </tr>
        <tr>
            <td id="signoz--affinity"><a href="./values.yaml#L1085">signoz.affinity</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Affinity settings for pod assignment.</td>
        </tr>
        <tr>
            <td id="signoz--topologySpreadConstraints"><a href="./values.yaml#L1089">signoz.topologySpreadConstraints</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Topology spread constraints for pod distribution.</td>
        </tr>
        <tr>
            <td id="signoz--persistence"><a href="./values.yaml#L1092">signoz.persistence</a></td>
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
            <td id="signoz--service"><a href="./values.yaml#L820">signoz.service</a></td>
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
            <td id="signoz--ingress"><a href="./values.yaml#L963">signoz.ingress</a></td>
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
            <td id="signoz--ingestionUrl"><a href="./values.yaml#L995">signoz.ingestionUrl</a></td>
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
            <td id="signoz--ingestPolicy--port"><a href="./values.yaml#L1005">signoz.ingestPolicy.port</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">4321</pre>
</div>
            </td>
            <td>Port of the OpAMP listener with TLS.</td>
        </tr>
        <tr>
            <td id="signoz--ingestPolicy--tokens--existingSecret"><a href="./values.yaml#L1012">signoz.ingestPolicy.tokens.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Secret holding the ingress collectors' tokens, one per line, 32 to 256 characters each, so a new token can be added before the old one is removed. The FuseScope collector presents the same Secret's token unless `fusescopeCollector.ingestToken` names another; it then needs exactly one token in it.</td>
        </tr>
        <tr>
            <td id="signoz--ingestPolicy--tokens--secretKey"><a href="./values.yaml#L1015">signoz.ingestPolicy.tokens.secretKey</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">tokens</pre>
</div>
            </td>
            <td>Key in `existingSecret` holding the tokens.</td>
        </tr>
        <tr>
            <td id="signoz--ingestPolicy--tls--existingSecret"><a href="./values.yaml#L1021">signoz.ingestPolicy.tls.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>`kubernetes.io/tls` Secret with the listener's `tls.crt` and `tls.key` for the FuseScope Service name, and the `ca.crt` the FuseScope collector verifies it with. Read again when it changes: a renewal needs no restart.</td>
        </tr>
        <tr>
            <td id="signoz--ingestPolicy--tls--caKey"><a href="./values.yaml#L1025">signoz.ingestPolicy.tls.caKey</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">ca.crt</pre>
</div>
            </td>
            <td>Key in the Secret holding the CA the FuseScope collector trusts; empty, the collector trusts the system roots.</td>
        </tr>
        <tr>
            <td id="signoz--ingestPolicy--tls--certManager"><a href="./values.yaml#L1030">signoz.ingestPolicy.tls.certManager</a></td>
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
            <td id="signoz--ingestPolicy--tls--clientCA"><a href="./values.yaml#L1041">signoz.ingestPolicy.tls.clientCA</a></td>
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
            <td id="signoz--retention--default--logs"><a href="./values.yaml#L1051">signoz.retention.default.logs</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Default logs retention in days. Empty keeps the schema default.</td>
        </tr>
        <tr>
            <td id="signoz--retention--default--traces"><a href="./values.yaml#L1054">signoz.retention.default.traces</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Default traces retention in days. Empty keeps the schema default.</td>
        </tr>
        <tr>
            <td id="signoz--retention--default--metrics"><a href="./values.yaml#L1057">signoz.retention.default.metrics</a></td>
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
            <td id="telemetryStoreMigrator"><a href="./values.yaml#L1112">telemetryStoreMigrator</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Default values for the Telemetry Store Migrator.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--enabled"><a href="./values.yaml#L1116">telemetryStoreMigrator.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Enable the Telemetry Store Migrator component.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--name"><a href="./values.yaml#L1120">telemetryStoreMigrator.name</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">signoz-telemetrystore-migrator</pre>
</div>
            </td>
            <td>The name of the Telemetry Store Migrator component.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--annotations"><a href="./values.yaml#L1124">telemetryStoreMigrator.annotations</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Annotations for the Telemetry Store Migrator job.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--upgradeHelmHooks"><a href="./values.yaml#L1128">telemetryStoreMigrator.upgradeHelmHooks</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Enable Helm pre-upgrade hooks and ArgoCD Sync hooks.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--enableReplication"><a href="./values.yaml#L1132">telemetryStoreMigrator.enableReplication</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Whether to enable replication for the Telemetry Store Migrator.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--timeout"><a href="./values.yaml#L1136">telemetryStoreMigrator.timeout</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">10m</pre>
</div>
            </td>
            <td>Timeout for the migration.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--nodeSelector"><a href="./values.yaml#L1140">telemetryStoreMigrator.nodeSelector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Node selector for pod assignment.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--tolerations"><a href="./values.yaml#L1144">telemetryStoreMigrator.tolerations</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Tolerations for pod assignment.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--affinity"><a href="./values.yaml#L1148">telemetryStoreMigrator.affinity</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Affinity settings for pod assignment.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--topologySpreadConstraints"><a href="./values.yaml#L1152">telemetryStoreMigrator.topologySpreadConstraints</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Topology spread constraints for pod distribution.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--resources"><a href="./values.yaml#L1156">telemetryStoreMigrator.resources</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Resource requests and limits for all migrator containers.</td>
        </tr>
        <tr>
            <td id="telemetryStoreMigrator--serviceAccount"><a href="./values.yaml#L1159">telemetryStoreMigrator.serviceAccount</a></td>
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
            <td id="otelCollector"><a href="./values.yaml#L1173">otelCollector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Default values for the OpenTelemetry Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--name"><a href="./values.yaml#L1177">otelCollector.name</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">otel-collector</pre>
</div>
            </td>
            <td>The name of the Otel Collector component.</td>
        </tr>
        <tr>
            <td id="otelCollector--image"><a href="./values.yaml#L1181">otelCollector.image</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Image configuration for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--imagePullSecrets"><a href="./values.yaml#L1198">otelCollector.imagePullSecrets</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Image pull secrets for the Otel Collector. This has higher precedence than the root level or global value.</td>
        </tr>
        <tr>
            <td id="otelCollector--strategy"><a href="./values.yaml#L1202">otelCollector.strategy</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">RollingUpdate</pre>
</div>
            </td>
            <td>Deployment strategy to use</td>
        </tr>
        <tr>
            <td id="otelCollector--command"><a href="./values.yaml#L1205">otelCollector.command</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">extraArgs: null
name: /fusescope-otel-collector</pre>
</div>
            </td>
            <td>Configuration for the Otel Collector executable.</td>
        </tr>
        <tr>
            <td id="otelCollector--configMap"><a href="./values.yaml#L1213">otelCollector.configMap</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">create: true</pre>
</div>
            </td>
            <td>ConfigMap settings.</td>
        </tr>
        <tr>
            <td id="otelCollector--serviceAccount"><a href="./values.yaml#L1219">otelCollector.serviceAccount</a></td>
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
            <td id="otelCollector--annotations"><a href="./values.yaml#L1247">otelCollector.annotations</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Annotations for the Otel Collector Deployment.</td>
        </tr>
        <tr>
            <td id="otelCollector--podAnnotations"><a href="./values.yaml#L1251">otelCollector.podAnnotations</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Annotations for the Otel Collector pod(s).</td>
        </tr>
        <tr>
            <td id="otelCollector--podLabels"><a href="./values.yaml#L1257">otelCollector.podLabels</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Labels for the Otel Collector pod(s).</td>
        </tr>
        <tr>
            <td id="otelCollector--additionalEnvs"><a href="./values.yaml#L1261">otelCollector.additionalEnvs</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Additional environment variables for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--lowCardinalityExceptionGrouping"><a href="./values.yaml#L1267">otelCollector.lowCardinalityExceptionGrouping</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Whether to enable grouping of exceptions with the same name but different stack traces. This is a tradeoff between cardinality and accuracy.</td>
        </tr>
        <tr>
            <td id="otelCollector--minReadySeconds"><a href="./values.yaml#L1271">otelCollector.minReadySeconds</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">5</pre>
</div>
            </td>
            <td>Minimum number of seconds for a new pod to be ready.</td>
        </tr>
        <tr>
            <td id="otelCollector--progressDeadlineSeconds"><a href="./values.yaml#L1275">otelCollector.progressDeadlineSeconds</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">600</pre>
</div>
            </td>
            <td>Maximum time in seconds for a deployment to make progress before it is considered failed.</td>
        </tr>
        <tr>
            <td id="otelCollector--replicaCount"><a href="./values.yaml#L1279">otelCollector.replicaCount</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">1</pre>
</div>
            </td>
            <td>The number of pod replicas for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--clusterRole"><a href="./values.yaml#L1283">otelCollector.clusterRole</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>RBAC ClusterRole configuration for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--livenessProbe"><a href="./values.yaml#L1526">otelCollector.livenessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Liveness probe configuration. ref: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-probes/#configure-probes</td>
        </tr>
        <tr>
            <td id="otelCollector--readinessProbe"><a href="./values.yaml#L1538">otelCollector.readinessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Readiness probe configuration.</td>
        </tr>
        <tr>
            <td id="otelCollector--customLivenessProbe"><a href="./values.yaml#L1550">otelCollector.customLivenessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Custom liveness probe to override the default.</td>
        </tr>
        <tr>
            <td id="otelCollector--customReadinessProbe"><a href="./values.yaml#L1554">otelCollector.customReadinessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Custom readiness probe to override the default.</td>
        </tr>
        <tr>
            <td id="otelCollector--extraVolumeMounts"><a href="./values.yaml#L1558">otelCollector.extraVolumeMounts</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Extra volume mounts for the Otel Collector pod.</td>
        </tr>
        <tr>
            <td id="otelCollector--extraVolumes"><a href="./values.yaml#L1562">otelCollector.extraVolumes</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Extra volumes for the Otel Collector pod.</td>
        </tr>
        <tr>
            <td id="otelCollector--resources"><a href="./values.yaml#L1599">otelCollector.resources</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">null</pre>
</div>
            </td>
            <td>Resource requests and limits. Ref: http://kubernetes.io/docs/user-guide/compute-resources/</td>
        </tr>
        <tr>
            <td id="otelCollector--priorityClassName"><a href="./values.yaml#L1610">otelCollector.priorityClassName</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Priority class for the Otel Collector pods.</td>
        </tr>
        <tr>
            <td id="otelCollector--nodeSelector"><a href="./values.yaml#L1614">otelCollector.nodeSelector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Node selector for pod assignment.</td>
        </tr>
        <tr>
            <td id="otelCollector--tolerations"><a href="./values.yaml#L1618">otelCollector.tolerations</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Tolerations for pod assignment.</td>
        </tr>
        <tr>
            <td id="otelCollector--affinity"><a href="./values.yaml#L1622">otelCollector.affinity</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Affinity settings for pod assignment.</td>
        </tr>
        <tr>
            <td id="otelCollector--topologySpreadConstraints"><a href="./values.yaml#L1626">otelCollector.topologySpreadConstraints</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Topology spread constraints for pod distribution.</td>
        </tr>
        <tr>
            <td id="otelCollector--podSecurityContext"><a href="./values.yaml#L1636">otelCollector.podSecurityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Pod-level security context.</td>
        </tr>
        <tr>
            <td id="otelCollector--securityContext"><a href="./values.yaml#L1642">otelCollector.securityContext</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Container-level security context.</td>
        </tr>
        <tr>
            <td id="otelCollector--autoscaling"><a href="./values.yaml#L1653">otelCollector.autoscaling</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Autoscaling configuration (HPA).</td>
        </tr>
        <tr>
            <td id="otelCollector--autoscaling--keda"><a href="./values.yaml#L1690">otelCollector.autoscaling.keda</a></td>
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
            <td id="otelCollector--service"><a href="./values.yaml#L1231">otelCollector.service</a></td>
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
            <td id="otelCollector--ingress"><a href="./values.yaml#L1565">otelCollector.ingress</a></td>
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
            <td id="otelCollector--ingress--hosts"><a href="./values.yaml#L1583">otelCollector.ingress.hosts</a></td>
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
            <td id="otelCollector--ports"><a href="./values.yaml#L1323">otelCollector.ports</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">Please checkout the default values in values.yml</pre>
</div>
            </td>
            <td>Port configurations for the Otel Collector.</td>
        </tr>
        <tr>
            <td id="otelCollector--ports--otlp"><a href="./values.yaml#L1326">otelCollector.ports.otlp</a></td>
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
            <td id="otelCollector--ports--otlp-http"><a href="./values.yaml#L1344">otelCollector.ports.otlp-http</a></td>
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
            <td id="otelCollector--ports--jaeger-compact"><a href="./values.yaml#L1362">otelCollector.ports.jaeger-compact</a></td>
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
            <td id="otelCollector--ports--jaeger-thrift"><a href="./values.yaml#L1380">otelCollector.ports.jaeger-thrift</a></td>
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
            <td id="otelCollector--ports--jaeger-grpc"><a href="./values.yaml#L1398">otelCollector.ports.jaeger-grpc</a></td>
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
            <td id="otelCollector--ports--zipkin"><a href="./values.yaml#L1416">otelCollector.ports.zipkin</a></td>
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
            <td id="otelCollector--ports--metrics"><a href="./values.yaml#L1434">otelCollector.ports.metrics</a></td>
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
            <td id="otelCollector--ports--zpages"><a href="./values.yaml#L1452">otelCollector.ports.zpages</a></td>
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
            <td id="otelCollector--ports--pprof"><a href="./values.yaml#L1470">otelCollector.ports.pprof</a></td>
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
            <td id="otelCollector--ports--logsheroku"><a href="./values.yaml#L1488">otelCollector.ports.logsheroku</a></td>
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
            <td id="otelCollector--ports--logsjson"><a href="./values.yaml#L1506">otelCollector.ports.logsjson</a></td>
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
            <td id="otelCollector--config"><a href="./values.yaml#L1715">otelCollector.config</a></td>
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
            <td id="mcpServer--enabled"><a href="./values.yaml#L1843">mcpServer.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Install the FuseScope MCP server in HTTP mode.</td>
        </tr>
        <tr>
            <td id="mcpServer--replicaCount"><a href="./values.yaml#L1846">mcpServer.replicaCount</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">1</pre>
</div>
            </td>
            <td>Number of replicas. The server is stateless.</td>
        </tr>
        <tr>
            <td id="mcpServer--image"><a href="./values.yaml#L1849">mcpServer.image</a></td>
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
            <td id="mcpServer--imagePullSecrets"><a href="./values.yaml#L1857">mcpServer.imagePullSecrets</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Image pull secrets. Overrides the root and global values.</td>
        </tr>
        <tr>
            <td id="mcpServer--fusescopeUrl"><a href="./values.yaml#L1862">mcpServer.fusescopeUrl</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">http://RELEASE-fusescope:8080, the backend Service</pre>
</div>
            </td>
            <td>FuseScope URL the server calls, and the only one it accepts in a client's `X-SigNoz-URL` header (`FUSESCOPE_INSTANCE_URL_ALLOWLIST`).</td>
        </tr>
        <tr>
            <td id="mcpServer--apiKey--existingSecret"><a href="./values.yaml#L1869">mcpServer.apiKey.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Secret holding a key the server uses for clients that send none. WARNING: anyone who can reach the endpoint then acts with this key's role. Use a Viewer service account, and keep the endpoint private (NetworkPolicy, no public ingress).</td>
        </tr>
        <tr>
            <td id="mcpServer--apiKey--secretKey"><a href="./values.yaml#L1872">mcpServer.apiKey.secretKey</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">api-key</pre>
</div>
            </td>
            <td>Key in `existingSecret` holding the API key.</td>
        </tr>
        <tr>
            <td id="mcpServer--docsRefreshInterval"><a href="./values.yaml#L1877">mcpServer.docsRefreshInterval</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">6h</pre>
</div>
            </td>
            <td>Incremental refresh of the docs index from docs.fusescope.fuseone.io (`FUSESCOPE_DOCS_REFRESH_INTERVAL`); `"0"` turns it off.</td>
        </tr>
        <tr>
            <td id="mcpServer--docsFullRefreshInterval"><a href="./values.yaml#L1883">mcpServer.docsFullRefreshInterval</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">24h</pre>
</div>
            </td>
            <td>Full rebuild of the docs index (`FUSESCOPE_DOCS_FULL_REFRESH_INTERVAL`); `"0"` turns it off. With both off the server serves the docs bundled with its release and needs no egress to the internet.</td>
        </tr>
        <tr>
            <td id="mcpServer--logLevel"><a href="./values.yaml#L1886">mcpServer.logLevel</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">info</pre>
</div>
            </td>
            <td>`debug`, `info`, `warn` or `error`.</td>
        </tr>
        <tr>
            <td id="mcpServer--extraEnv"><a href="./values.yaml#L1890">mcpServer.extraEnv</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Extra environment variables, e.g. `OTEL_EXPORTER_OTLP_ENDPOINT`, or `FUSESCOPE_CUSTOM_HEADERS` from a Secret.</td>
        </tr>
        <tr>
            <td id="mcpServer--serviceAccount"><a href="./values.yaml#L1893">mcpServer.serviceAccount</a></td>
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
            <td id="mcpServer--service"><a href="./values.yaml#L1899">mcpServer.service</a></td>
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
            <td id="mcpServer--ingress"><a href="./values.yaml#L1906">mcpServer.ingress</a></td>
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
            <td id="mcpServer--networkPolicy"><a href="./values.yaml#L1918">mcpServer.networkPolicy</a></td>
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
            <td id="mcpServer--resources"><a href="./values.yaml#L1934">mcpServer.resources</a></td>
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
            <td id="mcpServer--podSecurityContext"><a href="./values.yaml#L1942">mcpServer.podSecurityContext</a></td>
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
            <td id="mcpServer--securityContext"><a href="./values.yaml#L1951">mcpServer.securityContext</a></td>
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
            <td id="mcpServer--livenessProbe"><a href="./values.yaml#L1959">mcpServer.livenessProbe</a></td>
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
            <td id="mcpServer--readinessProbe"><a href="./values.yaml#L1966">mcpServer.readinessProbe</a></td>
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
            <td id="mcpServer--podAnnotations"><a href="./values.yaml#L1973">mcpServer.podAnnotations</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Pod annotations.</td>
        </tr>
        <tr>
            <td id="mcpServer--priorityClassName"><a href="./values.yaml#L1976">mcpServer.priorityClassName</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Priority class.</td>
        </tr>
        <tr>
            <td id="mcpServer--nodeSelector"><a href="./values.yaml#L1979">mcpServer.nodeSelector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Node selector.</td>
        </tr>
        <tr>
            <td id="mcpServer--tolerations"><a href="./values.yaml#L1982">mcpServer.tolerations</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Tolerations.</td>
        </tr>
        <tr>
            <td id="mcpServer--affinity"><a href="./values.yaml#L1985">mcpServer.affinity</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Affinity.</td>
        </tr>
        <tr>
            <td id="mcpServer--topologySpreadConstraints"><a href="./values.yaml#L1988">mcpServer.topologySpreadConstraints</a></td>
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
            <td id="fusescopeCollector--enabled"><a href="./values.yaml#L1998">fusescopeCollector.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Install the FuseScope collector as the ingress for Real User Monitoring: it serves `/rum/v1/traces` and `/rum/v1/logs`, takes the ingest policy from FuseScope over OpAMP with TLS (`signoz.ingestPolicy`) and writes ClickHouse directly. Needs a FuseScope release with the ingest policy listener (fuseone-io/fusescope#314), `signoz.ingestPolicy.tokens` and both TLS certificates.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--replicaCount"><a href="./values.yaml#L2002">fusescopeCollector.replicaCount</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">1</pre>
</div>
            </td>
            <td>Number of replicas. Each holds its own copy of the policy and reports its own counts; rate limits apply per replica.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--image"><a href="./values.yaml#L2007">fusescopeCollector.image</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">digest: sha256:894e8718ceb8c6785997f49014fe8efea9c246122f175504ed980e51afcea028
pullPolicy: IfNotPresent
registry: ghcr.io
repository: fuseone-io/fusescope-collector
tag: 0.1.0</pre>
</div>
            </td>
            <td>Collector image, by `tag` and `digest`: with both, the image is `<tag>@<digest>` and the digest is what is pulled. The default is the signed 0.1.0 multi-arch index.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--imagePullSecrets"><a href="./values.yaml#L2015">fusescopeCollector.imagePullSecrets</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Image pull secrets. Overrides the root and global values.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--ingestToken--existingSecret"><a href="./values.yaml#L2021">fusescopeCollector.ingestToken.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">signoz.ingestPolicy.tokens.existingSecret</pre>
</div>
            </td>
            <td>Secret holding the one token, 32 to 256 characters, the collector presents to FuseScope.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--ingestToken--secretKey"><a href="./values.yaml#L2025">fusescopeCollector.ingestToken.secretKey</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">signoz.ingestPolicy.tokens.secretKey</pre>
</div>
            </td>
            <td>Key in `existingSecret` holding the token.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--opamp--endpoint"><a href="./values.yaml#L2030">fusescopeCollector.opamp.endpoint</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">wss://RELEASE-fusescope:4321/v1/opamp, from signoz.ingestPolicy.port</pre>
</div>
            </td>
            <td>OpAMP endpoint of FuseScope with TLS.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--opamp--clientCertSecret"><a href="./values.yaml#L2034">fusescopeCollector.opamp.clientCertSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>`kubernetes.io/tls` Secret with the client certificate the collector presents when `signoz.ingestPolicy.tls.clientCA` is set.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--port"><a href="./values.yaml#L2038">fusescopeCollector.rum.port</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">4319</pre>
</div>
            </td>
            <td>Port of the RUM listener, TLS 1.3 only.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--tls--existingSecret"><a href="./values.yaml#L2044">fusescopeCollector.rum.tls.existingSecret</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>`kubernetes.io/tls` Secret with the RUM listener's `tls.crt` and `tls.key`. Behind the ingress it is the certificate between the ingress controller and the collector, so a cluster-internal one does.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--tls--certManager"><a href="./values.yaml#L2048">fusescopeCollector.rum.tls.certManager</a></td>
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
            <td id="fusescopeCollector--rum--trustedProxies"><a href="./values.yaml#L2061">fusescopeCollector.rum.trustedProxies</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">10.0.0.0/8, 172.16.0.0/12 and 192.168.0.0/16 with the ingress on, else none</pre>
</div>
            </td>
            <td>CIDRs whose `X-Forwarded-For` is read for the per-client rate limit, walked from the right past the trusted addresses. Behind an ingress or load balancer it must cover them, or every browser shares one limit.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--maxBodySize"><a href="./values.yaml#L2065">fusescopeCollector.rum.maxBodySize</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">4.194304e+06</pre>
</div>
            </td>
            <td>Largest accepted request body in bytes, before and after gzip decoding.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--rateLimit--key--rate"><a href="./values.yaml#L2071">fusescopeCollector.rum.rateLimit.key.rate</a></td>
            <td>float</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">500</pre>
</div>
            </td>
            <td>Requests per second shared by every client of one key, per replica, when the policy gives the key no limit.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--rateLimit--key--burst"><a href="./values.yaml#L2074">fusescopeCollector.rum.rateLimit.key.burst</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">1000</pre>
</div>
            </td>
            <td>Burst size of the per-key limit.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--rateLimit--client--rate"><a href="./values.yaml#L2079">fusescopeCollector.rum.rateLimit.client.rate</a></td>
            <td>float</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">20</pre>
</div>
            </td>
            <td>Requests per second per key and client IP, per replica.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--rateLimit--client--burst"><a href="./values.yaml#L2082">fusescopeCollector.rum.rateLimit.client.burst</a></td>
            <td>int</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">60</pre>
</div>
            </td>
            <td>Burst size of the per-client limit.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--rum--maxStaleness"><a href="./values.yaml#L2087">fusescopeCollector.rum.maxStaleness</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Refuse RUM requests, and report not ready, once the policy held was last received longer ago than this, e.g. `1h`. Empty, a policy held keeps working through a FuseScope outage.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--selfMetrics--enabled"><a href="./values.yaml#L2093">fusescopeCollector.selfMetrics.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">true</pre>
</div>
            </td>
            <td>Write the collector's own telemetry (receivers, processors, exporters, queues, memory) to ClickHouse as `otelcol_*` metrics. It is read from its listener on 127.0.0.1:8888, which is never exposed.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--selfMetrics--scrapeInterval"><a href="./values.yaml#L2096">fusescopeCollector.selfMetrics.scrapeInterval</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">60s</pre>
</div>
            </td>
            <td>How often the telemetry is read.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--serviceAccount"><a href="./values.yaml#L2099">fusescopeCollector.serviceAccount</a></td>
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
            <td id="fusescopeCollector--service"><a href="./values.yaml#L2105">fusescopeCollector.service</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">annotations: {}
type: ClusterIP</pre>
</div>
            </td>
            <td>Service for the RUM listener.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--ingress"><a href="./values.yaml#L2114">fusescopeCollector.ingress</a></td>
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
            <td>Ingress for `/rum/v1/traces` and `/rum/v1/logs`, `Exact`, so the browser SDK FuseScope serves at `/rum/v1/sdk/` stays on its ingress. It re-encrypts to the collector's TLS listener. Without `hosts`, it uses the hosts, TLS and class of `signoz.ingress`. Its annotations are not inherited; the defaults tell ingress-nginx the backend speaks HTTPS and raise its 1m body limit to `rum.maxBodySize`; another controller needs its own equivalents.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--storage"><a href="./values.yaml#L2126">fusescopeCollector.storage</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">sizeLimit: 64Mi</pre>
</div>
            </td>
            <td>Volume of the OpAMP state: the instance UID, the cached ingest policy and the report sequence. An emptyDir keeps them across container restarts; on a new pod the collector registers as a new agent and waits for the policy before it is ready.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--resources"><a href="./values.yaml#L2131">fusescopeCollector.resources</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">limits:
    memory: 512Mi
requests:
    cpu: 100m
    memory: 256Mi</pre>
</div>
            </td>
            <td>Resources. The memory limit is also what `memory_limiter` refuses data above (80%).</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--podSecurityContext"><a href="./values.yaml#L2140">fusescopeCollector.podSecurityContext</a></td>
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
            <td id="fusescopeCollector--securityContext"><a href="./values.yaml#L2149">fusescopeCollector.securityContext</a></td>
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
            <td id="fusescopeCollector--livenessProbe"><a href="./values.yaml#L2157">fusescopeCollector.livenessProbe</a></td>
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
            <td id="fusescopeCollector--readinessProbe"><a href="./values.yaml#L2165">fusescopeCollector.readinessProbe</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">failureThreshold: 3
initialDelaySeconds: 5
periodSeconds: 5
timeoutSeconds: 5</pre>
</div>
            </td>
            <td>Readiness probe timing on the health status, ready only while the collector holds a valid ingest policy.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--podAnnotations"><a href="./values.yaml#L2172">fusescopeCollector.podAnnotations</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Pod annotations.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--priorityClassName"><a href="./values.yaml#L2175">fusescopeCollector.priorityClassName</a></td>
            <td>string</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">""</pre>
</div>
            </td>
            <td>Priority class.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--nodeSelector"><a href="./values.yaml#L2178">fusescopeCollector.nodeSelector</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Node selector.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--tolerations"><a href="./values.yaml#L2181">fusescopeCollector.tolerations</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Tolerations.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--affinity"><a href="./values.yaml#L2184">fusescopeCollector.affinity</a></td>
            <td>object</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">{}</pre>
</div>
            </td>
            <td>Affinity.</td>
        </tr>
        <tr>
            <td id="fusescopeCollector--topologySpreadConstraints"><a href="./values.yaml#L2187">fusescopeCollector.topologySpreadConstraints</a></td>
            <td>list</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">[]</pre>
</div>
            </td>
            <td>Topology spread constraints.</td>
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
            <td id="postgresql--enabled"><a href="./values.yaml#L2195">postgresql.enabled</a></td>
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
            <td id="engine--enabled"><a href="./values.yaml#L2204">engine.enabled</a></td>
            <td>bool</td>
            <td>
                <div style="max-width: 300px;"><pre lang="yaml">false</pre>
</div>
            </td>
            <td>Install the FuseScope engine, the Parquet storage and query layer that will replace ClickHouse. Experimental and under construction: leave it off. Its settings are the fusescope-engine chart's values under `engine`.</td>
        </tr>
    </tbody>
</table>

