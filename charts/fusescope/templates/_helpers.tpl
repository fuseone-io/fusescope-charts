{{/* vim: set filetype=mustache: */}}

{{/*
Expand the name of the chart.
*/}}
{{- define "signoz.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name for SigNoz.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "signoz.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "signoz.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return namespace of the signoz release
*/}}
{{- define "signoz.namespace" -}}
{{- .Release.Namespace -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "signoz.labels" -}}
helm.sh/chart: {{ include "signoz.chart" . }}
{{ include "signoz.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "signoz.selectorLabels" -}}
app.kubernetes.io/name: {{ include "signoz.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ default "signoz" .Values.signoz.name }}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "signoz.serviceAccountName" -}}
{{- if .Values.signoz.serviceAccount.create -}}
    {{ default (include "signoz.fullname" .) .Values.signoz.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.signoz.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Return the proper signoz image name
*/}}
{{- define "signoz.image" -}}
{{- $registryName := default .Values.signoz.image.registry .Values.global.imageRegistry -}}
{{- $repositoryName := .Values.signoz.image.repository -}}
{{- $tag := default .Chart.AppVersion .Values.signoz.image.tag | toString -}}
{{- if $registryName -}}
    {{- printf "%s/%s:%s" $registryName $repositoryName $tag -}}
{{- else -}}
    {{- printf "%s:%s" $repositoryName $tag -}}
{{- end -}}
{{- end -}}

{{/*
Set signoz port
*/}}
{{- define "signoz.port" -}}
{{- default 8080 .Values.signoz.service.port  -}}
{{- end -}}

{{/*
Set signoz internal port
*/}}
{{- define "signoz.internalPort" -}}
{{- default 8085 .Values.signoz.service.internalPort  -}}
{{- end -}}

{{/*
Set signoz url
*/}}
{{- define "signoz.url" -}}
{{ include "signoz.fullname" . }}:{{ include "signoz.port" . }}
{{- end -}}

{{/*
Set signoz internal url
*/}}
{{- define "signoz.internalUrl" -}}
{{ include "signoz.fullname" . }}:{{ include "signoz.internalPort" . }}
{{- end -}}


{{/*
Create a default fully qualified app name for telemetrystore migrator.
*/}}
{{- define "telemetryStoreMigrator.fullname" -}}
{{- default "signoz-telemetrystore-migrator" .Values.telemetryStoreMigrator.name -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "telemetryStoreMigrator.labels" -}}
helm.sh/chart: {{ include "signoz.chart" . }}
{{ include "telemetryStoreMigrator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Common Selector labels of telemetrystore migrator
*/}}
{{- define "telemetryStoreMigrator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "signoz.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ default "telemetrystore-migrator" .Values.telemetryStoreMigrator.name }}
{{- end -}}


{{/*
Create a default fully qualified app name for otelCollector.
*/}}
{{- define "otelCollector.fullname" -}}
{{- printf "%s-%s" (include "signoz.fullname" .) .Values.otelCollector.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return the service name of Clickhouse
*/}}
{{- define "clickhouse.servicename" -}}
{{- if .Values.clickhouse.fullnameOverride -}}
{{- .Values.clickhouse.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "clickhouse" .Values.clickhouse.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- $name = .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else }}
{{- $name = printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- $namespace := .Values.clickhouse.namespace -}}
{{- $clusterDomain := default "cluster.local" .Values.global.clusterDomain -}}
{{- if and $namespace (ne $namespace .Release.Namespace) -}}
{{ printf "%s.%s.svc.%s" $name $namespace $clusterDomain }}
{{- else -}}
{{ $name }}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Return the service fqdn of Postgresql
*/}}
{{- define "postgresql.service" -}}
{{- if .Values.postgresql.enabled -}}
{{- $username := "$(POSTGRES_USER)" -}}
{{- $password := "$(POSTGRES_PASSWORD)" -}}
{{- $database := "$(POSTGRES_DB)" -}}
{{- $port := "$(POSTGRES_PORT)" -}}
{{- $name := "" -}}
{{- if .Values.postgresql.fullnameOverride -}}
  {{- $name = .Values.postgresql.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
  {{- $name = default "postgresql" .Values.postgresql.nameOverride -}}
  {{- if contains $name .Release.Name -}}
    {{- $name = .Release.Name | trunc 63 | trimSuffix "-" -}}
  {{- else -}}
    {{- $name = printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
  {{- end -}}
{{- end -}}
{{- $namespace := .Values.postgresql.namespace -}}
{{- $clusterDomain := default "cluster.local" .Values.global.clusterDomain -}}
{{- if and $namespace (ne $namespace .Release.Namespace) -}}
{{ printf "postgres://%s:%s@%s.%s.svc.%s:%s/%s?sslmode=disable" $username $password $name $namespace $clusterDomain $port $database }}
{{- else -}}
{{ printf "postgres://%s:%s@%s:%s/%s?sslmode=disable" $username $password $name $port $database }}
{{- end -}}
{{- end }}
{{- end -}}


{{/*
Return `nodePort: null` if service type is ClusterIP
*/}}
{{- define "signoz.service.ifClusterIP" -}}
{{- if (eq . "ClusterIP") }}
nodePort: null
{{- end }}
{{- end }}


{{/*
Return the appropriate apiVersion for ingress.
*/}}
{{- define "ingress.apiVersion" -}}
  {{- if and (.Capabilities.APIVersions.Has "networking.k8s.io/v1") (semverCompare ">= 1.19-0" .Capabilities.KubeVersion.Version) -}}
      {{- print "networking.k8s.io/v1" -}}
  {{- else if .Capabilities.APIVersions.Has "networking.k8s.io/v1beta1" -}}
    {{- print "networking.k8s.io/v1beta1" -}}
  {{- else -}}
    {{- print "extensions/v1beta1" -}}
  {{- end -}}
{{- end -}}

{{/*
Return if ingress supports pathType.
*/}}
{{- define "ingress.supportsPathType" -}}
  {{- or (eq (include "ingress.isStable" .) "true") (and (eq (include "ingress.apiVersion" .) "networking.k8s.io/v1beta1") (semverCompare ">= 1.18-0" .Capabilities.KubeVersion.Version)) -}}
{{- end -}}

{{/*
Return if ingress is stable.
*/}}
{{- define "ingress.isStable" -}}
  {{- eq (include "ingress.apiVersion" .) "networking.k8s.io/v1" -}}
{{- end -}}

{{/*
Return true if Let's Encrypt ClusterIssuer of `cert-manager` should be created.
*/}}
{{- define "ingress.letsencrypt" -}}
{{- $clusterIssuerEnabled := index (index .Values "cert-manager") "letsencrypt" -}}
{{- if ne ($clusterIssuerEnabled | toString) "<nil>" -}}
  {{ $clusterIssuerEnabled }}
{{- else if and (index (index .Values "ingress-nginx") "enabled") (index (index .Values "cert-manager") "enabled") -}}
  true
{{- else -}}
  false
{{- end -}}
{{- end -}}

{{/*
Common K8s environment variables used by SigNoz OtelCollector.
*/}}
{{- define "snippet.k8s-env" }}
- name: K8S_NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
- name: K8S_POD_IP
  valueFrom:
    fieldRef:
      apiVersion: v1
      fieldPath: status.podIP
- name: K8S_HOST_IP
  valueFrom:
    fieldRef:
      fieldPath: status.hostIP
- name: K8S_POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: K8S_POD_UID
  valueFrom:
    fieldRef:
      fieldPath: metadata.uid
- name: K8S_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
{{- end }}

{{/*
Return the proper Image Registry Secret Names.
*/}}
{{- define "signoz.imagePullSecrets" -}}
{{- if or .Values.global.imagePullSecrets .Values.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- range .Values.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}


{{/* 
Create Env
*/}}
{{- define "signoz.env" -}}

{{/*
====== Default ENV ======
*/}}
{{- $defaultEnv := dict
    "signoz_telemetrystore_clickhouse_dsn"     (printf "tcp://%s" (include "clickhouse.clickHouseUrl" .))
    "signoz_telemetrystore_clickhouse_cluster" (include "clickhouse.cluster" .)
}}

{{- $defaultEnv = merge $defaultEnv (include "signoz.ingestPolicyEnv" . | fromYaml) -}}
{{- $defaultEnv = merge $defaultEnv (include "signoz.proxyEnv" . | fromYaml) -}}
{{- $_ := set $defaultEnv "signoz_global_ingestion__url" (include "signoz.ingestionUrl" .) -}}
{{- $defaultEnv = merge $defaultEnv (include "signoz.retentionEnv" . | fromYaml) -}}

{{/*
SQL STORE POSTGRES ENV
*/}}
{{- $sqlStorePostgresEnv := dict -}}
{{- if .Values.postgresql.enabled }}
  {{- $_ := set $sqlStorePostgresEnv "postgres_port" .Values.postgresql.service.port }}
  {{- $_ := set $sqlStorePostgresEnv "postgres_user" .Values.postgresql.auth.username }}
  {{- if .Values.postgresql.auth.existingSecret }}
    {{- $secretCfg := default dict .Values.postgresql.auth.secretKeys }}
    {{- $secretKey := default "password" (get $secretCfg "userPasswordKey") }}
    {{- $_ := set $sqlStorePostgresEnv "postgres_password" (dict "valueFrom" (dict "secretKeyRef" (dict "name" .Values.postgresql.auth.existingSecret "key" $secretKey ))) }}
  {{- else }}
    {{- $_ := set $sqlStorePostgresEnv "postgres_password" .Values.postgresql.auth.password }}
  {{- end }}
  {{- if .Values.postgresql.auth.database }}
    {{- $_ := set $sqlStorePostgresEnv "postgres_db" .Values.postgresql.auth.database }}
  {{- end }}
{{- end }}
{{/*
SQL STORE ENV
Keep it seprate from sqlStorePostgresEnv to maintain the order of env variables
*/}}
{{- $sqlStoreEnv := dict -}}
{{- if .Values.postgresql.enabled -}}
{{ $sqlStoreEnv = merge $sqlStoreEnv ( dict "signoz_sqlstore_provider" "postgres")}}
{{ $sqlStoreEnv = merge $sqlStoreEnv ( dict "signoz_sqlstore_postgres_dsn" (include "postgresql.service" .))}}
{{- end }}


{{/*
===== USER ENV VARIABLES =====
*/}}
{{- $userEnv := .Values.signoz.env | default dict -}}


{{/*
====== MERGE AND RENDER ENV BLOCK ======
*/}}

{{- $completeEnv := mergeOverwrite $defaultEnv $userEnv $sqlStorePostgresEnv -}}
{{- template "signoz.renderEnv" $completeEnv -}}
{{/* Render the sqlstoreEnv (provider, dsn) seprately to maintain the order of the env variables */}}
{{- template "signoz.renderEnv" $sqlStoreEnv -}}
{{- end -}}

{{/*
OTLP/HTTP URL FuseScope shows for sending telemetry: signoz.ingestionUrl, else the
collector ingress (https when its host has TLS, on the path routed to the OTLP/HTTP
port), else the collector's in-cluster service.
*/}}
{{- define "signoz.ingestionUrl" -}}
{{- $collector := .Values.otelCollector -}}
{{- $httpPort := index $collector.ports "otlp-http" "servicePort" -}}
{{- if .Values.signoz.ingestionUrl -}}
{{- .Values.signoz.ingestionUrl -}}
{{- else if and $collector.ingress.enabled $collector.ingress.hosts -}}
{{- $rule := first $collector.ingress.hosts -}}
{{- $scheme := "http" -}}
{{- range $collector.ingress.tls -}}
{{- if has $rule.host .hosts }}{{ $scheme = "https" }}{{ end -}}
{{- end -}}
{{- $path := "" -}}
{{- with $rule.paths -}}
{{- $path = (first .).path -}}
{{- range . -}}
{{- if eq (toString .port) (toString $httpPort) }}{{ $path = .path }}{{ break }}{{ end -}}
{{- end -}}
{{- end -}}
{{- printf "%s://%s%s" $scheme $rule.host (trimSuffix "/" ($path | default "")) -}}
{{- else -}}
{{- printf "http://%s.%s.svc:%v" (include "otelCollector.fullname" .) .Release.Namespace $httpPort -}}
{{- end -}}
{{- end -}}

{{/*
Ingest policy env, as a YAML map: the OpAMP listener with TLS, its tokens and certificate.
*/}}
{{- define "signoz.ingestPolicyEnv" -}}
{{- if include "signoz.ingestPolicyEnabled" . }}
{{- $policy := .Values.signoz.ingestPolicy }}
signoz_rum_ingest__policy_token__file: {{ printf "%s/%s" (include "signoz.ingestPolicyDir" .) "tokens/tokens" | quote }}
signoz_rum_ingest__policy_listen: {{ printf "0.0.0.0:%v" $policy.port | quote }}
signoz_rum_ingest__policy_tls_cert__file: {{ printf "%s/%s" (include "signoz.ingestPolicyDir" .) "tls/tls.crt" | quote }}
signoz_rum_ingest__policy_tls_key__file: {{ printf "%s/%s" (include "signoz.ingestPolicyDir" .) "tls/tls.key" | quote }}
{{- if $policy.tls.clientCA.existingSecret }}
signoz_rum_ingest__policy_tls_client__ca__file: {{ printf "%s/%s" (include "signoz.ingestPolicyDir" .) "client-ca/ca.crt" | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Settings that followed the removed RUM gateway's, as a YAML map: the public dashboards trust
X-Forwarded-For behind the ingress, and the onboarding screen checks the in-chart collector's
OTLP/HTTP receiver. Each is set under its own key and, for releases before the gateway's
removal, under the rum key it used to read; later releases ignore the rum keys.
*/}}
{{- define "signoz.proxyEnv" -}}
{{- $collector := printf "http://%s:%v" (include "otelCollector.fullname" .) (index .Values.otelCollector.ports "otlp-http" "servicePort") }}
signoz_dashboard_public_ratelimit_trust__forwarded__for: {{ .Values.signoz.ingress.enabled | quote }}
signoz_rum_ratelimit_trust__forwarded__for: {{ .Values.signoz.ingress.enabled | quote }}
signoz_onboarding_collector__endpoint: {{ $collector | quote }}
signoz_rum_collector__endpoint: {{ $collector | quote }}
{{- end -}}

{{/*
True when FuseScope serves the ingest policy: a token Secret is set or the FuseScope collector
serves RUM.
*/}}
{{- define "signoz.ingestPolicyEnabled" -}}
{{- if or .Values.signoz.ingestPolicy.tokens.existingSecret (include "fusescopeCollector.rumEnabled" .) -}}
true
{{- end -}}
{{- end -}}

{{- define "signoz.ingestPolicyDir" -}}
/etc/fusescope/ingest
{{- end -}}

{{/*
Secret of the ingest policy listener's certificate.
*/}}
{{- define "signoz.ingestPolicyTLSSecret" -}}
{{- $tls := .Values.signoz.ingestPolicy.tls -}}
{{- if $tls.certManager.enabled -}}
{{- printf "%s-ingest-tls" (include "signoz.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- required "signoz.ingestPolicy.tls.existingSecret or signoz.ingestPolicy.tls.certManager.enabled is required: ingest tokens travel only over TLS" $tls.existingSecret -}}
{{- end -}}
{{- end -}}

{{- define "signoz.ingestPolicyTokensSecret" -}}
{{- required "signoz.ingestPolicy.tokens.existingSecret is required with fusescopeCollector.rum.enabled" .Values.signoz.ingestPolicy.tokens.existingSecret -}}
{{- end -}}

{{/*
DNS names of a Service in the release namespace, for a certificate.
*/}}
{{- define "fusescope.serviceDNSNames" -}}
{{- $name := .name -}}
{{- $ns := .namespace -}}
{{- toJson (list $name (printf "%s.%s" $name $ns) (printf "%s.%s.svc" $name $ns) (printf "%s.%s.svc.%s" $name $ns .clusterDomain)) -}}
{{- end -}}

{{/*
Default retention env, as a YAML map. Unset signals keep the schema default.
*/}}
{{- define "signoz.retentionEnv" -}}
{{- $default := (.Values.signoz.retention | default dict).default | default dict -}}
{{- range $signal := list "logs" "traces" "metrics" }}
{{- with index $default $signal }}
signoz_retention_default_{{ $signal }}: {{ int64 . | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Function to render environment variables 
*/}}
{{- define "signoz.renderEnv" -}}
{{- $dict := . -}}
{{- $processedKeys := dict -}}
{{- range keys . | sortAlpha | reverse }}
{{- $val := pluck . $dict | first -}}
{{- $key := upper . -}}
{{- if not (hasKey $processedKeys $key) }}
{{- $processedKeys = merge $processedKeys (dict $key true) -}}
{{- $valueType := printf "%T" $val -}}
{{- if eq $valueType "map[string]interface {}" }}
- name: {{ $key }}
{{ toYaml $val | indent 2 -}}
{{- else if eq $valueType "string" }}
- name: {{ $key }}
  value: {{ $val | quote }}
{{- else }}
- name: {{ $key }}
  value: {{ $val | quote}}
{{- end }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
MCP server
*/}}
{{- define "mcpServer.fullname" -}}
{{- printf "%s-mcp-server" (include "signoz.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mcpServer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "signoz.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: mcp-server
{{- end -}}

{{- define "mcpServer.labels" -}}
helm.sh/chart: {{ include "signoz.chart" . }}
{{ include "mcpServer.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.mcpServer.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "mcpServer.serviceAccountName" -}}
{{- if .Values.mcpServer.serviceAccount.create -}}
{{- default (include "mcpServer.fullname" .) .Values.mcpServer.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.mcpServer.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "mcpServer.image" -}}
{{- $image := .Values.mcpServer.image -}}
{{- $registry := default $image.registry .Values.global.imageRegistry -}}
{{- $name := ternary (printf "%s/%s" $registry $image.repository) $image.repository (not (empty $registry)) -}}
{{- if $image.digest -}}
{{- printf "%s@%s" $name $image.digest -}}
{{- else -}}
{{- printf "%s:%s" $name (toString $image.tag) -}}
{{- end -}}
{{- end -}}

{{/*
FuseScope URL the MCP server calls; the in-cluster backend Service unless set.
*/}}
{{- define "mcpServer.fusescopeUrl" -}}
{{- default (printf "http://%s" (include "signoz.url" .)) .Values.mcpServer.fusescopeUrl | trimSuffix "/" -}}
{{- end -}}

{{- define "mcpServer.docsRefreshEnabled" -}}
{{- $off := list "0" "off" "disabled" "false" -}}
{{- if and (has (toString .Values.mcpServer.docsRefreshInterval | lower) $off) (has (toString .Values.mcpServer.docsFullRefreshInterval | lower) $off) -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/*
Hosts of the MCP server ingress: its own, else the FuseScope ingress hosts.
*/}}
{{- define "mcpServer.ingressHosts" -}}
{{- $hosts := .Values.mcpServer.ingress.hosts -}}
{{- if and (not $hosts) .Values.signoz.ingress.enabled -}}
{{- range .Values.signoz.ingress.hosts -}}
{{- $hosts = append $hosts .host -}}
{{- end -}}
{{- end -}}
{{- if not $hosts -}}
{{- fail "mcpServer.ingress.hosts is required unless signoz.ingress is enabled" -}}
{{- end -}}
{{- toJson (uniq $hosts) -}}
{{- end -}}

{{/*
FuseScope collector
*/}}
{{- define "fusescopeCollector.fullname" -}}
{{- printf "%s-collector" (include "signoz.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fusescopeCollector.selectorLabels" -}}
app.kubernetes.io/name: {{ include "signoz.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: fusescope-collector
{{- end -}}

{{- define "fusescopeCollector.labels" -}}
helm.sh/chart: {{ include "signoz.chart" . }}
{{ include "fusescopeCollector.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.fusescopeCollector.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "fusescopeCollector.serviceAccountName" -}}
{{- if .Values.fusescopeCollector.serviceAccount.create -}}
{{- default (include "fusescopeCollector.fullname" .) .Values.fusescopeCollector.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.fusescopeCollector.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "fusescopeCollector.image" -}}
{{- $image := .Values.fusescopeCollector.image -}}
{{- $registry := default $image.registry .Values.global.imageRegistry -}}
{{- $name := ternary (printf "%s/%s" $registry $image.repository) $image.repository (not (empty $registry)) -}}
{{- if and $image.digest $image.tag -}}
{{- printf "%s:%s@%s" $name (toString $image.tag) $image.digest -}}
{{- else if $image.digest -}}
{{- printf "%s@%s" $name $image.digest -}}
{{- else -}}
{{- printf "%s:%s" $name (toString $image.tag) -}}
{{- end -}}
{{- end -}}

{{- define "fusescopeCollector.rumTLSSecret" -}}
{{- $tls := .Values.fusescopeCollector.rum.tls -}}
{{- if $tls.certManager.enabled -}}
{{- printf "%s-rum-tls" (include "fusescopeCollector.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- required "fusescopeCollector.rum.tls.existingSecret or fusescopeCollector.rum.tls.certManager.enabled is required: the RUM listener is TLS only" $tls.existingSecret -}}
{{- end -}}
{{- end -}}

{{/*
Secret and key of the ingest token the collector presents.
*/}}
{{- define "fusescopeCollector.tokenSecret" -}}
{{- default (include "signoz.ingestPolicyTokensSecret" .) .Values.fusescopeCollector.ingestToken.existingSecret -}}
{{- end -}}

{{- define "fusescopeCollector.tokenKey" -}}
{{- if .Values.fusescopeCollector.ingestToken.existingSecret -}}
{{- default "token" .Values.fusescopeCollector.ingestToken.secretKey -}}
{{- else -}}
{{- default .Values.signoz.ingestPolicy.tokens.secretKey .Values.fusescopeCollector.ingestToken.secretKey -}}
{{- end -}}
{{- end -}}

{{/*
OpAMP endpoint of FuseScope: its TLS listener for the ingest policy with RUM, else the in-cluster
plaintext listener.
*/}}
{{- define "fusescopeCollector.opampEndpoint" -}}
{{- if include "fusescopeCollector.rumEnabled" . -}}
{{- default (printf "wss://%s:%v/v1/opamp" (include "signoz.fullname" .) .Values.signoz.ingestPolicy.port) .Values.fusescopeCollector.opamp.endpoint -}}
{{- else -}}
{{- default (printf "ws://%s:%v/v1/opamp" (include "signoz.fullname" .) (default 4320 .Values.signoz.service.opampPort)) .Values.fusescopeCollector.opamp.endpoint -}}
{{- end -}}
{{- end -}}

{{/*
True when the FuseScope collector runs: enabled, with OTLP, RUM or the agents' listener to receive.
*/}}
{{- define "fusescopeCollector.active" -}}
{{- $c := .Values.fusescopeCollector -}}
{{- if and $c.enabled (or $c.otlp.enabled $c.rum.enabled $c.agentListener.enabled) -}}
true
{{- end -}}
{{- end -}}

{{/*
True when the FuseScope collector serves the agents' mTLS listener.
*/}}
{{- define "fusescopeCollector.agentListenerEnabled" -}}
{{- if and .Values.fusescopeCollector.enabled .Values.fusescopeCollector.agentListener.enabled -}}
true
{{- end -}}
{{- end -}}

{{- define "fusescopeCollector.agentListenerTLSSecret" -}}
{{- $tls := .Values.fusescopeCollector.agentListener.tls -}}
{{- if $tls.certManager.enabled -}}
{{- printf "%s-agents-tls" (include "fusescopeCollector.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- required "fusescopeCollector.agentListener.tls.existingSecret or fusescopeCollector.agentListener.tls.certManager.enabled is required: the agents' listener is TLS only" $tls.existingSecret -}}
{{- end -}}
{{- end -}}

{{/*
The CA bundle the agents' listener verifies client certificates with, as {"secret", "key"}:
clientCA's Secret, else the agents' certificate Secret.
*/}}
{{- define "fusescopeCollector.agentClientCA" -}}
{{- $ca := .Values.fusescopeCollector.agentListener.clientCA -}}
{{- $secret := $ca.existingSecret -}}
{{- if not $secret -}}
{{- $agentTLS := .Values.fusescopeAgent.tls -}}
{{- if not (or $agentTLS.existingSecret $agentTLS.certManager.enabled) -}}
{{- fail "fusescopeCollector.agentListener.clientCA.existingSecret, or fusescopeAgent.tls, is required: the CA bundle agent certificates must chain to" -}}
{{- end -}}
{{- $secret = include "fusescopeAgent.tlsSecret" . -}}
{{- end -}}
{{- toJson (dict "secret" $secret "key" (required "fusescopeCollector.agentListener.clientCA.key is required" $ca.key)) -}}
{{- end -}}

{{/*
Secret and key of the token the agents present and the listener requires.
*/}}
{{- define "fusescopeCollector.agentTokenSecret" -}}
{{- required "fusescopeCollector.agentListener.token.existingSecret is required: the agents' listener requires a token, read from a Secret" .Values.fusescopeCollector.agentListener.token.existingSecret -}}
{{- end -}}

{{- define "fusescopeCollector.agentTokenKey" -}}
{{- required "fusescopeCollector.agentListener.token.secretKey is required" .Values.fusescopeCollector.agentListener.token.secretKey -}}
{{- end -}}

{{/*
FuseScope agent: the collector in agent mode, a DaemonSet.
*/}}
{{- define "fusescopeAgent.fullname" -}}
{{- printf "%s-agent" (include "signoz.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fusescopeAgent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "signoz.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: fusescope-agent
{{- end -}}

{{- define "fusescopeAgent.labels" -}}
helm.sh/chart: {{ include "signoz.chart" . }}
{{ include "fusescopeAgent.selectorLabels" . }}
app.kubernetes.io/version: {{ default .Values.fusescopeCollector.image.tag .Values.fusescopeAgent.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "fusescopeAgent.serviceAccountName" -}}
{{- if .Values.fusescopeAgent.serviceAccount.create -}}
{{- default (include "fusescopeAgent.fullname" .) .Values.fusescopeAgent.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.fusescopeAgent.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
The agent's image. Empty fields take fusescopeCollector.image's; a tag or digest of its own
does not inherit the collector's digest.
*/}}
{{- define "fusescopeAgent.image" -}}
{{- $own := .Values.fusescopeAgent.image -}}
{{- $base := .Values.fusescopeCollector.image -}}
{{- $registry := default (default $base.registry $own.registry) .Values.global.imageRegistry -}}
{{- $repository := default $base.repository $own.repository -}}
{{- $name := ternary (printf "%s/%s" $registry $repository) $repository (not (empty $registry)) -}}
{{- $tag := toString (default $base.tag $own.tag) -}}
{{- $digest := ternary $base.digest $own.digest (and (empty $own.tag) (empty $own.digest)) -}}
{{- if and $digest $tag -}}
{{- printf "%s:%s@%s" $name $tag $digest -}}
{{- else if $digest -}}
{{- printf "%s@%s" $name $digest -}}
{{- else -}}
{{- printf "%s:%s" $name $tag -}}
{{- end -}}
{{- end -}}

{{- define "fusescopeAgent.tlsSecret" -}}
{{- $tls := .Values.fusescopeAgent.tls -}}
{{- if $tls.certManager.enabled -}}
{{- printf "%s-tls" (include "fusescopeAgent.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- required "fusescopeAgent.tls.existingSecret or fusescopeAgent.tls.certManager.enabled is required: the agents present a client certificate" $tls.existingSecret -}}
{{- end -}}
{{- end -}}

{{/*
Fails on agent settings that cannot work. Included first by every agent template.
*/}}
{{- define "fusescopeAgent.validate" -}}
{{- $a := .Values.fusescopeAgent -}}
{{- if and (not $a.gateway.endpoint) (not (include "fusescopeCollector.agentListenerEnabled" .)) -}}
{{- fail "fusescopeAgent.enabled needs fusescopeCollector.agentListener.enabled, or fusescopeAgent.gateway.endpoint for a gateway outside this release" -}}
{{- end -}}
{{- if not (or $a.podLogs.enabled $a.hostMetrics.enabled $a.kubeletStats.enabled) -}}
{{- fail "fusescopeAgent.enabled with nothing to collect: enable podLogs, hostMetrics or kubeletStats" -}}
{{- end -}}
{{- end -}}

{{/*
The agent's pod security context: uid 0 only to read pod logs or host metrics, else 65532;
runAsUser, runAsGroup and runAsNonRoot set in values win (collector-server ADR 0011).
*/}}
{{- define "fusescopeAgent.podSecurityContext" -}}
{{- $a := .Values.fusescopeAgent -}}
{{- $root := or $a.podLogs.enabled $a.hostMetrics.enabled -}}
{{- $default := dict "runAsUser" 65532 "runAsGroup" 65532 "runAsNonRoot" true -}}
{{- if $root -}}
{{- $default = dict "runAsUser" 0 "runAsGroup" 0 "runAsNonRoot" false -}}
{{- end -}}
{{- /* Key by key, not merge: merge would take a values 0 or false for unset. */ -}}
{{- $sc := deepCopy (default dict $a.podSecurityContext) -}}
{{- range $k, $v := $default -}}
{{- if not (hasKey $sc $k) -}}{{- $_ := set $sc $k $v -}}{{- end -}}
{{- end -}}
{{- $seccomp := default dict $sc.seccompProfile -}}
{{- if ne (toString $seccomp.type) "RuntimeDefault" -}}
{{- fail "fusescopeAgent.podSecurityContext.seccompProfile must be RuntimeDefault (collector-server ADR 0011)" -}}
{{- end -}}
{{- $nonRoot := and $sc.runAsNonRoot (ne (int $sc.runAsUser) 0) -}}
{{- if and (not $root) (not $nonRoot) -}}
{{- fail "fusescopeAgent runs as root only with podLogs or hostMetrics: with kubelet stats alone, podSecurityContext must keep a non-zero runAsUser and runAsNonRoot true (collector-server ADR 0011)" -}}
{{- end -}}
{{- /* A non-root agent reads its credentials, mounted 0440, through its group. */ -}}
{{- if and $nonRoot (not (hasKey $sc "fsGroup")) -}}
{{- $_ := set $sc "fsGroup" (default $sc.runAsUser $sc.runAsGroup) -}}
{{- end -}}
{{- toYaml $sc -}}
{{- end -}}

{{/*
The agent's container security context, refused unless it stays locked down. The user is the
pod's only, so a container setting cannot undo the non-root rule.
*/}}
{{- define "fusescopeAgent.securityContext" -}}
{{- $sc := default dict .Values.fusescopeAgent.securityContext -}}
{{- $caps := default dict $sc.capabilities -}}
{{- if or $sc.privileged (ne (toString $sc.allowPrivilegeEscalation) "false") (ne (toString $sc.readOnlyRootFilesystem) "true") $caps.add (not (has "ALL" (default list $caps.drop))) -}}
{{- fail "fusescopeAgent.securityContext must keep privileged and allowPrivilegeEscalation false, readOnlyRootFilesystem true, and drop ALL capabilities (collector-server ADR 0011)" -}}
{{- end -}}
{{- if or (hasKey $sc "runAsUser") (hasKey $sc "runAsGroup") (hasKey $sc "runAsNonRoot") -}}
{{- fail "fusescopeAgent.securityContext must not set runAsUser, runAsGroup or runAsNonRoot: the agent's user is fusescopeAgent.podSecurityContext's (collector-server ADR 0011)" -}}
{{- end -}}
{{- if and (hasKey $sc "seccompProfile") (ne (toString (default dict $sc.seccompProfile).type) "RuntimeDefault") -}}
{{- fail "fusescopeAgent.securityContext.seccompProfile, when set, must be RuntimeDefault (collector-server ADR 0011)" -}}
{{- end -}}
{{- toYaml $sc -}}
{{- end -}}

{{- define "fusescopeAgent.gatewayEndpoint" -}}
{{- default (printf "%s.%s.svc:%v" (include "fusescopeCollector.fullname" .) .Release.Namespace .Values.fusescopeCollector.agentListener.port) .Values.fusescopeAgent.gateway.endpoint -}}
{{- end -}}

{{/*
The CA bundle the agents verify the listener with, as {"secret", "key"}: gateway.ca's Secret,
else the listener's certificate Secret.
*/}}
{{- define "fusescopeAgent.gatewayCA" -}}
{{- $ca := .Values.fusescopeAgent.gateway.ca -}}
{{- $secret := $ca.existingSecret -}}
{{- if not $secret -}}
{{- if not (include "fusescopeCollector.agentListenerEnabled" .) -}}
{{- fail "fusescopeAgent.gateway.ca.existingSecret is required for a gateway outside this release: the CA bundle the agents verify it with" -}}
{{- end -}}
{{- $secret = include "fusescopeCollector.agentListenerTLSSecret" . -}}
{{- end -}}
{{- toJson (dict "secret" $secret "key" (required "fusescopeAgent.gateway.ca.key is required" $ca.key)) -}}
{{- end -}}

{{/*
True when the FuseScope collector serves RUM.
*/}}
{{- define "fusescopeCollector.rumEnabled" -}}
{{- if and .Values.fusescopeCollector.enabled .Values.fusescopeCollector.rum.enabled -}}
true
{{- end -}}
{{- end -}}

{{/*
True when the FuseScope collector receives OTLP.
*/}}
{{- define "fusescopeCollector.otlpEnabled" -}}
{{- if and .Values.fusescopeCollector.enabled .Values.fusescopeCollector.otlp.enabled -}}
true
{{- end -}}
{{- end -}}

{{/*
True when the FuseScope collector takes the earlier collector's Service name and OTLP ports.
Fails on otelCollector.enabled: the earlier collector was removed in 0.165.0.
*/}}
{{- define "fusescopeCollector.compatService" -}}
{{- if .Values.otelCollector.enabled -}}
{{- fail "otelCollector.enabled: true, the earlier collector (fusescope-otel-collector), was removed in 0.165.0. Remove the override: the FuseScope collector (fusescopeCollector) receives OTLP." -}}
{{- end -}}
{{- if include "fusescopeCollector.otlpEnabled" . -}}
true
{{- end -}}
{{- end -}}

{{- define "fusescopeCollector.trustedProxies" -}}
{{- $proxies := .Values.fusescopeCollector.rum.trustedProxies -}}
{{- if kindIs "invalid" $proxies -}}
{{- $proxies = ternary (list "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16") (list) .Values.fusescopeCollector.ingress.enabled -}}
{{- end -}}
{{- toJson $proxies -}}
{{- end -}}

{{/*
ClickHouse as the collector's exporter sees it: endpoint, user, TLS, databases, and where its
password comes from (a Secret and key, or none).
*/}}
{{/*
The connection settings of a fusescope_clickhouse exporter, from the dict of
fusescopeCollector.clickhouse.
*/}}
{{- define "fusescopeCollector.clickhouseConnection" -}}
endpoint: {{ .endpoint }}
{{- with .user }}
username: {{ . | quote }}
{{- end }}
{{- if .secret }}
password_file: /etc/fusescope-collector/clickhouse/password
{{- end }}
tls:
  insecure: {{ not .secure }}
  {{- if and .secure (not .verify) }}
  # clickhouse.verify / externalClickhouse.verify is false: TLS without
  # checking the server's certificate, as the chart's contract says.
  insecure_skip_verify: true
  {{- end }}
{{- end -}}

{{- define "fusescopeCollector.clickhouse" -}}
{{- $ch := ternary .Values.clickhouse .Values.externalClickhouse .Values.clickhouse.enabled -}}
{{- $host := ternary (include "clickhouse.servicename" .) $ch.host .Values.clickhouse.enabled -}}
{{- $out := dict
    "endpoint" (printf "%s:%s" (required "externalClickhouse.host is required if not clickhouse.enabled" $host) (include "clickhouse.tcpPort" .))
    "user" (toString $ch.user)
    "secure" $ch.secure
    "verify" $ch.verify
    "traces" (default "signoz_traces" $ch.traceDatabase)
    "logs" (default "signoz_logs" $ch.logDatabase)
    "metrics" (default "signoz_metrics" $ch.database)
    "meter" (default "signoz_meter" $ch.meterDatabase)
-}}
{{- if .Values.clickhouse.enabled -}}
{{- if .Values.clickhouse.password -}}
{{- $_ := set $out "secret" (printf "%s-clickhouse" (include "fusescopeCollector.fullname" .)) -}}
{{- $_ := set $out "key" "password" -}}
{{- end -}}
{{- else if or .Values.externalClickhouse.existingSecret .Values.externalClickhouse.password -}}
{{- $_ := set $out "secret" (include "clickhouse.secretName" . | trimAll "\"") -}}
{{- $_ := set $out "key" (include "clickhouse.secretPasswordKey" . | trimAll "\"") -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}
