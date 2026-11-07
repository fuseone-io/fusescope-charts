{{/*
fusescope-schema, the FuseScope schema migrator (collector ADR 0010): the Job
runs `migrate`, the collectors' init container `check --wait`. Both read one
connection, the FuseScope collector's, from one ConfigMap, and the password
only from a Secret mounted as a file.
*/}}

{{/*
True when telemetryStoreMigrator runs fusescope-schema; fails on settings it
cannot run with.
*/}}
{{- define "fusescopeSchema.enabled" -}}
{{- $m := .Values.telemetryStoreMigrator -}}
{{- if not (has $m.migrator (list "fusescope-schema" "fork")) -}}
{{- fail (printf "telemetryStoreMigrator.migrator must be \"fusescope-schema\" or \"fork\", not %q" (toString $m.migrator)) -}}
{{- end -}}
{{- if and $m.enabled (eq $m.migrator "fusescope-schema") -}}
{{- if not $m.enableReplication -}}
{{- fail "telemetryStoreMigrator.enableReplication: false is not supported by fusescope-schema: it migrates only the replicated schema (collector spec §2.1). Keep it true, or set telemetryStoreMigrator.migrator: fork" -}}
{{- end -}}
{{- if not $m.image.digest -}}
{{- fail "telemetryStoreMigrator.image.digest is required: fusescope-schema runs only a signed image pinned by digest" -}}
{{- end -}}
true
{{- end -}}
{{- end -}}

{{/*
True when the earlier collector's migrator runs instead.
*/}}
{{- define "telemetryStoreMigrator.fork" -}}
{{- if and .Values.telemetryStoreMigrator.enabled (eq .Values.telemetryStoreMigrator.migrator "fork") -}}
true
{{- end -}}
{{- end -}}

{{/*
fusescope-schema's ServiceAccount: telemetryStoreMigrator.serviceAccount.name,
or <migrator>-schema when the chart creates it.
*/}}
{{- define "fusescopeSchema.serviceAccountName" -}}
{{- $sa := .Values.telemetryStoreMigrator.serviceAccount -}}
{{- if $sa.create -}}
{{- default (printf "%s-schema" (include "telemetryStoreMigrator.fullname" . | trunc 56 | trimSuffix "-")) $sa.name -}}
{{- else -}}
{{- default "default" $sa.name -}}
{{- end -}}
{{- end -}}

{{- define "fusescopeSchema.image" -}}
{{- $image := .Values.telemetryStoreMigrator.image -}}
{{- $registry := default $image.registry .Values.global.imageRegistry -}}
{{- $name := ternary (printf "%s/%s" $registry $image.repository) $image.repository (not (empty $registry)) -}}
{{- if $image.tag -}}
{{- printf "%s:%s@%s" $name (toString $image.tag) $image.digest -}}
{{- else -}}
{{- printf "%s@%s" $name $image.digest -}}
{{- end -}}
{{- end -}}

{{/*
The connection, as the FuseScope collector's exporter has it, with the
cluster and every database. The in-chart password comes from the
migrator's own Secret, which exists whether or not the collector runs.
*/}}
{{- define "fusescopeSchema.connection" -}}
{{- $ch := include "fusescopeCollector.clickhouse" . | fromJson -}}
{{- if and .Values.clickhouse.enabled .Values.clickhouse.password -}}
{{- $_ := set $ch "secret" (printf "%s-clickhouse" (include "telemetryStoreMigrator.fullname" .)) -}}
{{- end -}}
{{- $_ := set $ch "cluster" (include "clickhouse.cluster" . | trim) -}}
{{- toJson $ch -}}
{{- end -}}

{{/*
fusescope-schema's configuration file (its --config), without the password.
*/}}
{{- define "fusescopeSchema.config" -}}
{{- $ch := include "fusescopeSchema.connection" . | fromJson -}}
{{- $tls := dict "insecure" (not $ch.secure) -}}
{{- if and $ch.secure (not $ch.verify) -}}
{{- $_ := set $tls "insecure_skip_verify" true -}}
{{- end -}}
{{- $cfg := dict
    "endpoint" $ch.endpoint
    "tls" $tls
    "cluster" $ch.cluster
    "databases" (dict
      "traces" $ch.traces "logs" $ch.logs "metrics" $ch.metrics "meter" $ch.meter
      "metadata" "signoz_metadata" "analytics" "signoz_analytics")
-}}
{{- with $ch.user -}}
{{- $_ := set $cfg "username" . -}}
{{- end -}}
{{- if $ch.secret -}}
{{- $_ := set $cfg "password_file" "/etc/fusescope-schema/clickhouse/password" -}}
{{- end -}}
{{- toPrettyJson $cfg -}}
{{- end -}}

{{/*
The Job's name carries a hash of the image and the configuration: a change
creates a new Job instead of editing an immutable one.
*/}}
{{- define "fusescopeSchema.jobName" -}}
{{- $hash := printf "%s\n%s" (include "fusescopeSchema.image" .) (include "fusescopeSchema.config" .) | sha256sum | trunc 10 -}}
{{- printf "%s-%s" (include "telemetryStoreMigrator.fullname" . | trunc 52 | trimSuffix "-") $hash -}}
{{- end -}}

{{- define "fusescopeSchema.configMapName" -}}
{{- printf "%s-config" (include "telemetryStoreMigrator.fullname" . | trunc 56 | trimSuffix "-") -}}
{{- end -}}

{{- define "fusescopeSchema.volumeMounts" -}}
{{- $ch := include "fusescopeSchema.connection" . | fromJson -}}
- name: fusescope-schema-config
  mountPath: /etc/fusescope-schema/config
  readOnly: true
{{- if $ch.secret }}
- name: fusescope-schema-clickhouse
  mountPath: /etc/fusescope-schema/clickhouse
  readOnly: true
{{- end }}
{{- end -}}

{{- define "fusescopeSchema.volumes" -}}
{{- $ch := include "fusescopeSchema.connection" . | fromJson -}}
- name: fusescope-schema-config
  configMap:
    name: {{ include "fusescopeSchema.configMapName" . }}
{{- if $ch.secret }}
- name: fusescope-schema-clickhouse
  secret:
    secretName: {{ $ch.secret }}
    defaultMode: 0440
    items:
      - key: {{ $ch.key }}
        path: password
{{- end }}
{{- end -}}

{{/*
The init container that waits, without writing, until the schema is up to
date: `check --wait` exits 0, or fails the pod's start on a refusal or when
the wait passes.
*/}}
{{- define "fusescopeSchema.checkContainer" -}}
- name: schema
  image: {{ include "fusescopeSchema.image" . }}
  imagePullPolicy: {{ .Values.telemetryStoreMigrator.image.pullPolicy }}
  command: ["/fusescope-schema"]
  args:
    - check
    - --wait={{ .Values.telemetryStoreMigrator.timeout | default "10m" }}
    - --config=/etc/fusescope-schema/config/config.json
  securityContext:
    {{- toYaml .Values.telemetryStoreMigrator.securityContext | nindent 4 }}
  volumeMounts:
    {{- include "fusescopeSchema.volumeMounts" . | nindent 4 }}
  {{- with .Values.telemetryStoreMigrator.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
