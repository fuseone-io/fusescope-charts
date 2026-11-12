{{- define "fsp.name" -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "fsp.labels" -}}
app.kubernetes.io/name: fusescope-parity
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "fsp.selector" -}}
app.kubernetes.io/name: fusescope-parity
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* The destinations each workload reaches. */}}
{{- define "fsp.destinations" -}}
{{- $direct := dict "run" (list "dns" "apiServer" "engine" "clickhouse" "prometheus" "pushgateway") "cleanup" (list "dns" "apiServer") "investigate" (list "dns" "engine" "clickhouse" "prometheus" "audit") -}}
{{- $sts := ternary (list) (list "sts") (not (empty .Values.secrets.bucketRun)) -}}
{{- $outside := dict "run" (concat (list "bucket") $sts) "cleanup" (list) "investigate" (concat (list "bucket") $sts (list "idp")) -}}
{{- $names := index $direct .component -}}
{{- $far := index $outside .component -}}
{{- if and .Values.proxy.url $far -}}
{{- $names = append $names "proxy" -}}
{{- else -}}
{{- $names = concat $names $far -}}
{{- end -}}
{{- join " " $names -}}
{{- end -}}

{{/* Minutes of the day, from 0, that a job scheduled at .minute spans: its starting and active deadlines and the margin, rounded up. */}}
{{- define "fsp.span" -}}
{{- div (add .startingDeadlineSeconds .activeDeadlineSeconds .margin 59) 60 -}}
{{- end -}}

{{/* The hours the hourly round runs: every hour whose span stays clear of the daily round's, both ways round the clock. */}}
{{- define "fsp.hourlyHours" -}}
{{- $v := .Values -}}
{{- $h := $v.rounds.hourly -}}
{{- $d := $v.rounds.daily -}}
{{- $hs := int (include "fsp.span" (dict "startingDeadlineSeconds" $h.startingDeadlineSeconds "activeDeadlineSeconds" $h.activeDeadlineSeconds "margin" $v.marginSeconds)) -}}
{{- $ds := int (include "fsp.span" (dict "startingDeadlineSeconds" $d.startingDeadlineSeconds "activeDeadlineSeconds" $d.activeDeadlineSeconds "margin" $v.marginSeconds)) -}}
{{- $daily := add (mul (int $d.hour) 60) (int $d.minute) -}}
{{- $hours := list -}}
{{- range $hour := until 24 -}}
{{- $start := add (mul $hour 60) (int $h.minute) -}}
{{- $after := mod (add (sub $start $daily) 1440) 1440 -}}
{{- $before := mod (add (sub $daily $start) 1440) 1440 -}}
{{- if and (ge $after $ds) (ge $before $hs) -}}
{{- $hours = append $hours $hour -}}
{{- end -}}
{{- end -}}
{{- join "," $hours -}}
{{- end -}}

{{/* Refuses a release that would run half-configured, unpinned or wider than it must. */}}
{{- define "fsp.validate" -}}
{{- $v := .Values -}}
{{- $_ := required "image.repository" $v.image.repository -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" (required "image.digest: the index digest parity-image.yaml signed" $v.image.digest)) -}}
{{- fail (printf "image.digest must be sha256:<64 hex>, not %q" $v.image.digest) -}}
{{- end -}}
{{- range $key := list "engineClient" "clickhouse" "pushgateway" "prometheus" "audit" -}}
{{- $_ := required (printf "secrets.%s" $key) (index $v.secrets $key) -}}
{{- end -}}
{{- $names := compact (values (pick $v.secrets "engineClient" "clickhouse" "pushgateway" "prometheus" "audit" "bucketRun" "bucketInvestigate")) -}}
{{- if ne (len $names) (len (uniq $names)) -}}
{{- fail (printf "every Secret must differ, since each workload mounts only some of them: %v" $names) -}}
{{- end -}}
{{- if ne (empty $v.secrets.bucketRun) (empty $v.secrets.bucketInvestigate) -}}
{{- fail "secrets.bucketRun and secrets.bucketInvestigate: both or neither, so neither workload falls back to another identity" -}}
{{- end -}}
{{- if and $v.bucket.caConfigMap (not $v.bucket.endpoint) -}}
{{- fail "bucket.caConfigMap: a CA of its own is for a store of its own, at bucket.endpoint" -}}
{{- end -}}
{{- if and $v.bucket.endpoint $v.proxy.url -}}
{{- fail "bucket.endpoint: a store of its own is reached directly, not through proxy.url" -}}
{{- end -}}
{{- $_ := required "tenants.configMap: the tenants file D1 maintains" $v.tenants.configMap -}}
{{- $_ := required "engine.endpoint" $v.engine.endpoint -}}
{{- $_ := required "engine.serverName" $v.engine.serverName -}}
{{- $_ := required "bucket.name" $v.bucket.name -}}
{{- $_ := required "bucket.kmsKeyId" $v.bucket.kmsKeyId -}}
{{- $_ := required "pushgateway.url" $v.pushgateway.url -}}
{{- $_ := required "health.url" $v.health.url -}}
{{- $_ := required "investigate.issuer" $v.investigate.issuer -}}
{{- $_ := required "investigate.group" $v.investigate.group -}}
{{- $_ := required "investigate.auditEndpoint" $v.investigate.auditEndpoint -}}
{{- $_ := required "oncall.group" $v.oncall.group -}}
{{- if eq $v.runKeys.namespace .Release.Namespace -}}
{{- fail "runKeys.namespace must differ from the release's: it holds only the run keys" -}}
{{- end -}}
{{- with $v.round -}}
{{- if and (hasKey . "max_rows") (ge (int64 .windowed_above) (int64 .max_rows)) -}}
{{- fail "round.windowed_above must stay below round.max_rows" -}}
{{- end -}}
{{- end -}}
{{- range $class := list "hourly" "daily" -}}
{{- $r := index $v.rounds $class -}}
{{- if lt (int $r.activeDeadlineSeconds) (add (int $r.budgetSeconds) (int $v.marginSeconds)) -}}
{{- fail (printf "rounds.%s.activeDeadlineSeconds must be at least budgetSeconds + marginSeconds (%d)" $class (add (int $r.budgetSeconds) (int $v.marginSeconds))) -}}
{{- end -}}
{{- end -}}
{{- if not (include "fsp.hourlyHours" .) -}}
{{- fail "no hour is left for the hourly round clear of the daily one" -}}
{{- end -}}
{{- range $dest, $rules := $v.egress -}}
{{- range $rule := $rules -}}
{{- range $peer := $rule.to -}}
{{- with $peer.ipBlock -}}
{{- if not (regexMatch "^[0-9a-fA-F:.]+/[0-9]{1,3}$" .cidr) -}}
{{- fail (printf "egress.%s: %q is not a CIDR" $dest .cidr) -}}
{{- end -}}
{{- $prefix := int (last (splitList "/" .cidr)) -}}
{{- if lt $prefix (ternary 32 8 (contains ":" .cidr)) -}}
{{- fail (printf "egress.%s: %s is wider than /%d" $dest .cidr (ternary 32 8 (contains ":" .cidr))) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $component := list "run" "cleanup" "investigate" -}}
{{- range $dest := splitList " " (include "fsp.destinations" (dict "component" $component "Values" $v)) -}}
{{- if not (index $v.egress $dest) -}}
{{- fail (printf "egress.%s: the %s workload reaches it" $dest $component) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* The settings file of a round of .class, or of the investigation. */}}
{{- define "fsp.settings" -}}
{{- $v := .Values -}}
{{- $round := deepCopy $v.round -}}
{{- if .class -}}
{{- $_ := set $round "budget" (printf "%ds" (int (index $v.rounds .class).budgetSeconds)) -}}
{{- end -}}
{{- $jwt := dict "key_file" "/etc/parity/engine/jwt.pem" -}}
{{- with $v.engine.jwtIssuer }}{{ $_ := set $jwt "issuer" . }}{{ end -}}
{{- with $v.engine.jwtAudience }}{{ $_ := set $jwt "audience" . }}{{ end -}}
{{- $clickhouse := dict -}}
{{- with $v.clickhouse.cluster }}{{ $_ := set $clickhouse "cluster" . }}{{ end -}}
{{- $settings := dict
  "version" 1
  "engine" (dict "provider" "flight" "flight" (dict
    "endpoint" $v.engine.endpoint
    "tls" (dict "cert_file" "/etc/parity/engine/tls.crt" "key_file" "/etc/parity/engine/tls.key" "ca_file" "/etc/parity/engine/ca.crt" "server_name" $v.engine.serverName)
    "jwt" $jwt))
  "clickhouse" (dict "provider" "clickhouse" "clickhouse" $clickhouse)
  "credentials" (dict "clickhouse_dsn_file" "/etc/parity/clickhouse/dsn")
  "pushgateway" (dict "url" $v.pushgateway.url "token_file" "/etc/parity/pushgateway/token")
  "bucket" (dict "name" $v.bucket.name "kms_key_id" $v.bucket.kmsKeyId "path_style" $v.bucket.pathStyle)
  "secret" (dict "namespace" $v.runKeys.namespace "expiry" $v.runKeys.expiry)
  "health" (dict "url" $v.health.url "token_file" "/etc/parity/prometheus/token" "instance_label" $v.health.instanceLabel "exporters" $v.health.exporters)
  "investigate" (dict "issuer" $v.investigate.issuer "audience" $v.investigate.audience "group" $v.investigate.group "audit_endpoint" $v.investigate.auditEndpoint "audit_token_file" "/etc/parity/audit/token")
-}}
{{- if $round }}{{ $_ := set $settings "round" $round }}{{ end -}}
{{- toYaml $settings -}}
{{- end -}}

{{/* The hosts reached directly when a proxy is set: the cluster's and every in-cluster endpoint. */}}
{{- define "fsp.noProxy" -}}
{{- $v := .Values -}}
{{- $hosts := list ".svc" ".cluster.local" (first (splitList ":" $v.engine.endpoint)) -}}
{{- range $u := list $v.pushgateway.url $v.health.url $v.investigate.auditEndpoint -}}
{{- $hosts = append $hosts (first (splitList ":" (urlParse $u).host)) -}}
{{- end -}}
{{- with $v.proxy.noProxy }}{{ $hosts = append $hosts . }}{{ end -}}
{{- join "," (uniq $hosts) -}}
{{- end -}}

{{/* The pod spec of .component, with its .args, .account and .volumes (names of Secrets, tenants, settings, reports). */}}
{{- define "fsp.pod" -}}
{{- $v := .Values -}}
serviceAccountName: {{ include "fsp.name" . }}-{{ .account }}
automountServiceAccountToken: true
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
  seccompProfile:
    type: RuntimeDefault
{{- with $v.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $v.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $v.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $v.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .restartPolicy }}
restartPolicy: {{ . }}
{{- end }}
containers:
  - name: parity
    image: "{{ $v.image.repository }}@{{ $v.image.digest }}"
    imagePullPolicy: {{ $v.image.pullPolicy }}
    args: {{ toJson .args }}
    env:
      - name: PARITY_IMAGE_DIGEST
        value: {{ $v.image.digest | quote }}
      {{- with $v.build.backendCommit }}
      - name: PARITY_BACKEND_COMMIT
        value: {{ . | quote }}
      {{- end }}
      {{- with $v.build.engineVersion }}
      - name: PARITY_ENGINE_VERSION
        value: {{ . | quote }}
      {{- end }}
      {{- if ne .component "cleanup" }}
      {{- with $v.bucket.endpoint }}
      - name: AWS_ENDPOINT_URL_S3
        value: {{ . | quote }}
      {{- end }}
      {{- with $v.bucket.region }}
      - name: AWS_REGION
        value: {{ . | quote }}
      {{- end }}
      {{- if $v.secrets.bucketRun }}
      - name: AWS_SHARED_CREDENTIALS_FILE
        value: /etc/parity/bucket/credentials
      {{- end }}
      {{- if $v.bucket.caConfigMap }}
      - name: AWS_CA_BUNDLE
        value: /etc/parity/bucket-ca/ca.crt
      {{- end }}
      {{- if $v.trust.caConfigMap }}
      - name: SSL_CERT_FILE
        value: /etc/parity/trust/ca-bundle.crt
      {{- end }}
      {{- end }}
      {{- if and $v.proxy.url (has "proxy" (splitList " " (include "fsp.destinations" .))) }}
      - name: HTTPS_PROXY
        value: {{ $v.proxy.url | quote }}
      - name: NO_PROXY
        value: {{ include "fsp.noProxy" . | quote }}
      {{- end }}
    securityContext:
      readOnlyRootFilesystem: true
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    {{- with .resources }}
    resources:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    volumeMounts:
      - name: settings
        mountPath: /etc/parity/settings
        readOnly: true
      {{- if has "tenants" .volumes }}
      - name: tenants
        mountPath: /etc/parity/tenants
        readOnly: true
      {{- end }}
      {{- range $name := list "engineClient" "clickhouse" "pushgateway" "prometheus" "audit" }}
      {{- if has $name $.volumes }}
      - name: {{ $name | kebabcase }}
        mountPath: /etc/parity/{{ $name | replace "engineClient" "engine" }}
        readOnly: true
      {{- end }}
      {{- end }}
      {{- if has "reports" .volumes }}
      - name: reports
        mountPath: /var/lib/parity/reports
      {{- end }}
      {{- with .bucketSecret }}
      - name: bucket
        mountPath: /etc/parity/bucket
        readOnly: true
      {{- end }}
      {{- if and (ne .component "cleanup") $v.bucket.caConfigMap }}
      - name: bucket-ca
        mountPath: /etc/parity/bucket-ca
        readOnly: true
      {{- end }}
      {{- if and (ne .component "cleanup") $v.trust.caConfigMap }}
      - name: trust
        mountPath: /etc/parity/trust
        readOnly: true
      {{- end }}
volumes:
  - name: settings
    configMap:
      name: {{ include "fsp.name" . }}-settings
  {{- if has "tenants" .volumes }}
  - name: tenants
    configMap:
      name: {{ $v.tenants.configMap }}
      items:
        - key: {{ $v.tenants.key }}
          path: tenants.yaml
  {{- end }}
  {{- range $name := list "engineClient" "clickhouse" "pushgateway" "prometheus" "audit" }}
  {{- if has $name $.volumes }}
  - name: {{ $name | kebabcase }}
    secret:
      secretName: {{ index $v.secrets $name }}
      defaultMode: 0440
  {{- end }}
  {{- end }}
  {{- if has "reports" .volumes }}
  - name: reports
    emptyDir:
      sizeLimit: {{ $v.reportsSizeLimit }}
  {{- end }}
  {{- with .bucketSecret }}
  - name: bucket
    secret:
      secretName: {{ . }}
      defaultMode: 0440
      items:
        - key: credentials
          path: credentials
  {{- end }}
  {{- if and (ne .component "cleanup") $v.bucket.caConfigMap }}
  - name: bucket-ca
    configMap:
      name: {{ $v.bucket.caConfigMap }}
      items:
        - key: ca.crt
          path: ca.crt
  {{- end }}
  {{- if and (ne .component "cleanup") $v.trust.caConfigMap }}
  - name: trust
    configMap:
      name: {{ $v.trust.caConfigMap }}
      items:
        - key: ca-bundle.crt
          path: ca-bundle.crt
  {{- end }}
{{- end -}}
