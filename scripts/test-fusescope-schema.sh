#!/usr/bin/env bash
# Installs the chart on a kind cluster with fusescope-schema as its migrator:
#   1. a fresh install on an empty ClickHouse;
#   2. the published chart (the fork's migrator), upgraded once to itself, as a
#      running cluster is, then upgraded to this one, which adopts the fork's
#      schema, then the same upgrade again, a no-op;
#   3. an external ClickHouse, its password in a custom Secret and key;
#   4. enableReplication: false, refused before anything is installed;
#   5. an external ClickHouse without keeper_map_path_prefix: exit 2, retried
#      until backoffLimit, each attempt naming the setting;
#   6. an external ClickHouse holding a table of its own: exit 1, the Job failed
#      at once by its podFailurePolicy;
#   7. an external ClickHouse lost while 0001 is started: exit 4, the same;
#   8. a second upgrade while 0001 is started: the first Job is kept and
#      finishes, the second waits for the lease and finds it up to date.
# Every kubectl and helm call names the kind context; nothing else is touched.
#   scripts/test-fusescope-schema.sh        KEEP=1 keeps the cluster
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=${KIND_CLUSTER:-fusescope-schema}
CTX=kind-$NAME
PUBLISHED=${PUBLISHED_VERSION:-0.161.1}
CH_IMAGE=clickhouse/clickhouse-server:25.12.5@sha256:cacf32d6884291dc2ff5e0156a97f46fc53ff7c929a7906d114e268a929dfd3a
k() { kubectl --context "$CTX" "$@"; }
h() { helm --kube-context "$CTX" "$@"; }
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Always a new cluster: a release left by an earlier run would start at
# another revision, with a schema already there.
kind delete cluster --name "$NAME" >/dev/null 2>&1 || true
kind create cluster --name "$NAME" --wait 120s
[ "${KEEP:-}" = 1 ] || trap 'kind delete cluster --name "$NAME" >/dev/null 2>&1' EXIT
helm dependency build charts/fusescope >/dev/null
helm repo add --force-update fusescope https://fuseone-io.github.io/fusescope-charts >/dev/null

migrator=app.kubernetes.io/component=signoz-telemetrystore-migrator

# deploy_ch NAMESPACE PASSWORD PREFIX: a single ClickHouse 25.12 with an
# embedded Keeper, the cluster ext, its shard and replica macros, a user
# fusescope, and keeper_map_path_prefix unless PREFIX is "none".
deploy_ch() {
  local ns=$1 password=$2 prefix=$3 setting=""
  [ "$prefix" = none ] || setting="<keeper_map_path_prefix>$prefix</keeper_map_path_prefix>"
  k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata: {name: ch-users}
stringData:
  users.xml: |
    <clickhouse><users><fusescope>
      <password>$password</password>
      <networks><ip>::/0</ip></networks>
      <profile>default</profile><quota>default</quota>
      <access_management>1</access_management>
    </fusescope></users></clickhouse>
---
apiVersion: v1
kind: ConfigMap
metadata: {name: ch-config}
data:
  cluster.xml: |
    <clickhouse>
      <listen_host>0.0.0.0</listen_host>
      <keeper_server><tcp_port>9181</tcp_port><server_id>1</server_id>
        <log_storage_path>/var/lib/clickhouse/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse/coordination/snapshots</snapshot_storage_path>
        <raft_configuration><server><id>1</id><hostname>localhost</hostname><port>9234</port></server></raft_configuration>
      </keeper_server>
      <zookeeper><node><host>localhost</host><port>9181</port></node></zookeeper>
      $setting
      <macros><shard>1</shard><replica>ch-0</replica></macros>
      <remote_servers><ext><shard><internal_replication>true</internal_replication>
        <replica><host>ch-0.ch.$ns.svc.cluster.local</host><port>9000</port></replica>
      </shard></ext></remote_servers>
    </clickhouse>
---
apiVersion: v1
kind: Service
metadata: {name: ch}
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector: {app: ch}
  ports: [{name: native, port: 9000}, {name: http, port: 8123}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: ch}
spec:
  serviceName: ch
  replicas: 1
  selector: {matchLabels: {app: ch}}
  template:
    metadata: {labels: {app: ch}}
    spec:
      containers:
        - name: clickhouse
          image: $CH_IMAGE
          env: [{name: CLICKHOUSE_SKIP_USER_SETUP, value: "1"}]
          ports: [{containerPort: 9000}, {containerPort: 8123}]
          readinessProbe: {tcpSocket: {port: 9000}, periodSeconds: 2}
          volumeMounts:
            - {name: config, mountPath: /etc/clickhouse-server/config.d/cluster.xml, subPath: cluster.xml}
            - {name: users, mountPath: /etc/clickhouse-server/users.d/fusescope.xml, subPath: users.xml}
      volumes:
        - {name: config, configMap: {name: ch-config}}
        - {name: users, secret: {secretName: ch-users}}
EOF
  k -n "$ns" rollout status statefulset/ch --timeout=5m
}

# install_external NAMESPACE CH_NAMESPACE PASSWORD: the chart against it,
# the password in the custom Secret my-ch-credentials, key ch-pass.
install_external() { # NAMESPACE CH_NAMESPACE PASSWORD [--set ...]
  local ns=$1 chns=$2 password=$3; shift 3
  k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "$ns" create secret generic my-ch-credentials --from-literal=ch-pass="$password" --dry-run=client -o yaml | k apply -f - >/dev/null
  h upgrade -i "$ns" charts/fusescope -n "$ns" --wait=false \
    --set clickhouse.enabled=false \
    --set externalClickhouse.host=ch-0.ch.$chns.svc.cluster.local \
    --set externalClickhouse.cluster=ext \
    --set externalClickhouse.user=fusescope \
    --set externalClickhouse.existingSecret=my-ch-credentials \
    --set externalClickhouse.existingSecretPasswordKey=ch-pass "$@" >/dev/null
}

exits_of() { # NAMESPACE JOB: each pod's exit code, one per line
  k -n "$1" get pods -l "job-name=${2#job.batch/}" -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}{end}'
}

# wait_failed_at_once NAMESPACE JOB EXIT: failed by the podFailurePolicy,
# after a single pod that exited EXIT.
wait_failed_at_once() {
  local ns=$1 job=$2 code=$3
  k -n "$ns" wait --for=condition=failed "$job" --timeout=10m >/dev/null || fail "$ns: $job did not fail"
  local reason; reason=$(k -n "$ns" get "$job" -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}')
  [ "$reason" = PodFailurePolicy ] || fail "$ns: $job failed by $reason, not its podFailurePolicy"
  local exits; exits=$(k -n "$ns" get pods -l "job-name=${job#job.batch/}" -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}{end}')
  [ "$exits" = "$code" ] || fail "$ns: $job's pods exited [$exits], want one exit $code"
}

# fusescope-schema's Job of the latest revision: <migrator>-r<revision>-<hash>.
schema_job() { k -n "$1" get jobs -l "$migrator" -o name | grep -E 'signoz-telemetrystore-migrator-r[0-9]+-[0-9a-f]{8}$' | sort -V | tail -1 || true; }

# next_job NAMESPACE PREVIOUS: the Job after PREVIOUS, once it exists.
next_job() {
  local job
  for _ in $(seq 60); do job=$(schema_job "$1"); [ -n "$job" ] && [ "$job" != "$2" ] && { echo "$job"; return; }; sleep 5; done
  fail "$1: no new fusescope-schema Job after $2"
}

wait_job() { # NAMESPACE JOB: complete, or fail with its logs
  local ns=$1 job=$2
  if ! k -n "$ns" wait --for=condition=complete "$job" --timeout=15m; then
    k -n "$ns" logs "$job" --all-containers --tail=50 >&2 || true
    fail "$ns: $job did not complete"
  fi
}

wait_collector() { # NAMESPACE: the FuseScope collector's Deployment, past its check --wait
  local deploy; deploy=$(k -n "$1" get deploy -o name | grep -E -- '-collector$' | grep -v otel-collector)
  [ -n "$deploy" ] || fail "$1: no FuseScope collector Deployment"
  k -n "$1" rollout status "$deploy" --timeout=10m
}

expect_logs() { # NAMESPACE JOB PATTERN...: the logs of the attempt that succeeded
  local ns=$1 job=$2; shift 2
  local pod; pod=$(k -n "$ns" get pods -l "job-name=${job#job.batch/}" --field-selector=status.phase=Succeeded -o name | head -1)
  [ -n "$pod" ] || fail "$ns: $job has no succeeded pod"
  local logs; logs=$(k -n "$ns" logs "$pod")
  for p in "$@"; do grep -q -- "$p" <<<"$logs" || { echo "$logs" >&2; fail "$ns: $job logs lack '$p'"; }; done
  echo "$logs"
}

step "1. fresh install"
# Finished Jobs go after a minute here, a day by default.
TTL="--set telemetryStoreMigrator.ttlSecondsAfterFinished=60"
# A fresh install: the Job starts beside ClickHouse, retries exit 2 until it is up.
h upgrade -i fresh charts/fusescope -n fresh --create-namespace --wait=false $TTL >/dev/null
for _ in $(seq 60); do job=$(schema_job fresh); [ -n "$job" ] && break; sleep 5; done
[ -n "$job" ] || fail "fresh: no fusescope-schema Job"
wait_job fresh "$job"
expect_logs fresh "$job" "starting point: empty" "applied 0001 base" "up to date"
retried=$(k -n fresh get pods -l "job-name=${job#job.batch/}" -o jsonpath='{range .items[*]}{.status.phase}:{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}{end}')
grep -qx 'Failed:2' <<<"$retried" || fail "fresh: no attempt exited 2 before ClickHouse was up: [$retried]"
echo "attempts: $(tr '\n' ' ' <<<"$retried")"
wait_collector fresh
# A change to the Job's pod template only: a new Job, a no-op migration.
first=$job
h upgrade fresh charts/fusescope -n fresh --reuse-values --set telemetryStoreMigrator.resources.limits.memory=256Mi --wait=false >/dev/null
job=$(next_job fresh "$first")
k -n fresh get "$first" >/dev/null 2>&1 || fail "fresh: helm deleted the previous Job, $first"
wait_job fresh "$job"
logs=$(expect_logs fresh "$job" "starting point: managed" "up to date")
grep -q "applied" <<<"$logs" && fail "fresh: the no-op Job applied a migration"
echo "after a resources change: $job, up to date; $first kept by helm"
gone=
for _ in $(seq 60); do k -n fresh get "$first" >/dev/null 2>&1 || { gone=1; break; }; sleep 5; done
[ -n "$gone" ] || fail "fresh: $first was not removed after its ttlSecondsAfterFinished"
echo "$first removed by its ttlSecondsAfterFinished"

step "2. the published chart $PUBLISHED, then this one: adoption"
h upgrade -i adopt fusescope/fusescope --version "$PUBLISHED" -n adopt --create-namespace --wait=false >/dev/null
k -n adopt wait --for=condition=complete job/signoz-telemetrystore-migrator --timeout=15m
# Upgraded once: the earlier migrator's Job and ServiceAccount are now hooks.
# helm waits for the pre-upgrade Job and fails with it, then removes it as
# gone from the release.
h upgrade adopt fusescope/fusescope --version "$PUBLISHED" -n adopt --wait=false --timeout 15m >/dev/null
chpods() { k -n adopt get pods -l clickhouse.altinity.com/chi -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' | sort; }
before=$(chpods)
[ -n "$before" ] || fail "adopt: no ClickHouse pod"
h upgrade adopt charts/fusescope -n adopt --wait=false >/dev/null
for _ in $(seq 60); do job=$(schema_job adopt); [ -n "$job" ] && break; sleep 5; done
[ -n "$job" ] || fail "adopt: no fusescope-schema Job after the upgrade"
wait_job adopt "$job"
expect_logs adopt "$job" "starting point: fork 0.145.0" "up to date"
k -n adopt get serviceaccount signoz-telemetrystore-migrator-schema >/dev/null || fail "adopt: fusescope-schema's ServiceAccount is gone after the upgrade"
k -n adopt get job signoz-telemetrystore-migrator >/dev/null 2>&1 && fail "adopt: the fork's Job is still there"
# keeper_map_path_prefix rolled every ClickHouse pod; fusescope-schema's
# KeeperMap tables exist, so the setting is in force.
for _ in $(seq 60); do after=$(chpods); [ -z "$(comm -12 <(echo "$before") <(echo "$after"))" ] && break; sleep 5; done
[ -z "$(comm -12 <(echo "$before") <(echo "$after"))" ] || fail "adopt: ClickHouse pods not replaced after keeper_map_path_prefix: $(comm -12 <(echo "$before") <(echo "$after"))"
echo "ClickHouse pods replaced: $(wc -l <<<"$before") before, $(wc -l <<<"$after") after"
wait_collector adopt
# The same upgrade again: a new Job of the next revision, a no-op.
h upgrade adopt charts/fusescope -n adopt --wait=false >/dev/null
again=$(next_job adopt "$job")
wait_job adopt "$again"
logs=$(expect_logs adopt "$again" "starting point: managed" "up to date")
grep -q "applied" <<<"$logs" && fail "adopt: the repeated upgrade applied a migration"
echo "the same upgrade again: $again, up to date"

step "3. an external ClickHouse, the password in a custom Secret"
password=fs-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
deploy_ch ext-ch "$password" /keeper_map
install_external external ext-ch "$password"
for _ in $(seq 60); do job=$(schema_job external); [ -n "$job" ] && break; sleep 5; done
[ -n "$job" ] || fail "external: no fusescope-schema Job"
wait_job external "$job"
logs=$(expect_logs external "$job" "starting point: empty" "applied 0001 base")
grep -q -- "$password" <<<"$logs" && fail "external: the password is in the Job's logs"
k -n external get "$job" -o yaml | grep -q -- "$password" && fail "external: the password is in the Job"
k -n external get configmap signoz-telemetrystore-migrator-config -o yaml | grep -q -- "$password" && fail "external: the password is in the ConfigMap"
wait_collector external

step "4. enableReplication: false is refused before anything is installed"
if h upgrade -i refused charts/fusescope -n refused --create-namespace --set telemetryStoreMigrator.enableReplication=false >/dev/null 2>err.txt; then
  fail "refused: the install went through"
fi
grep -q "enableReplication: false is not supported by fusescope-schema" err.txt || { cat err.txt >&2; fail "refused: another error"; }
rm -f err.txt
k -n refused get jobs 2>/dev/null | grep -q . && fail "refused: something was installed"

step "5. an external ClickHouse without keeper_map_path_prefix: exit 2, retried"
deploy_ch ext-noprefix "$password" none
install_external noprefix ext-noprefix "$password" --set telemetryStoreMigrator.backoffLimit=1
for _ in $(seq 60); do job=$(schema_job noprefix); [ -n "$job" ] && break; sleep 5; done
[ -n "$job" ] || fail "noprefix: no fusescope-schema Job"
k -n noprefix wait --for=condition=failed "$job" --timeout=10m >/dev/null || fail "noprefix: $job did not fail"
reason=$(k -n noprefix get "$job" -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}')
[ "$reason" = BackoffLimitExceeded ] || fail "noprefix: $job failed by $reason, not BackoffLimitExceeded: exit 2 is retried"
exits=$(exits_of noprefix "$job")
[ "$(sort -u <<<"$exits")" = 2 ] && [ "$(wc -l <<<"$exits")" -ge 2 ] || fail "noprefix: exits [$exits], want 2 on every attempt, retried"
for pod in $(k -n noprefix get pods -l "job-name=${job#job.batch/}" -o name); do
  k -n noprefix logs "$pod" | grep -q "set keeper_map_path_prefix in the ClickHouse server configuration" \
    || { k -n noprefix logs "$pod" >&2; fail "noprefix: $pod does not name keeper_map_path_prefix"; }
done
echo "attempts exited $(tr '\n' ' ' <<<"$exits")- $reason; each names keeper_map_path_prefix"
# Fixed, then the same upgrade: the failed Job is not reused, a new one runs.
k -n ext-noprefix get configmap ch-config -o json \
  | jq '.data["cluster.xml"] |= sub("<zookeeper>"; "<keeper_map_path_prefix>/keeper_map</keeper_map_path_prefix><zookeeper>")' \
  | k -n ext-noprefix apply -f - >/dev/null
k -n ext-noprefix delete pod ch-0 >/dev/null
k -n ext-noprefix rollout status statefulset/ch --timeout=5m >/dev/null
failed=$job
# No kubectl delete job: the same upgrade runs a new Job of the next revision.
install_external noprefix ext-noprefix "$password" --set telemetryStoreMigrator.backoffLimit=1
job=$(next_job noprefix "$failed")
wait_job noprefix "$job"
expect_logs noprefix "$job" "starting point: empty" "applied 0001 base" >/dev/null
echo "after the fix and the same upgrade: $job migrated; the failed $failed was left as it was"

step "6. an external ClickHouse holding a table of its own: exit 1, failed at once"
deploy_ch ext-drift "$password" /keeper_map
k -n ext-drift exec ch-0 -- clickhouse-client -u fusescope --password "$password" -n -q \
  "CREATE DATABASE signoz_logs; CREATE TABLE signoz_logs.not_ours (k String) ENGINE = MergeTree ORDER BY k" 2>/dev/null
install_external drift ext-drift "$password"
for _ in $(seq 60); do job=$(schema_job drift); [ -n "$job" ] && break; sleep 5; done
[ -n "$job" ] || fail "drift: no fusescope-schema Job"
wait_failed_at_once drift "$job" 1
k -n drift logs "$job" | grep -q "logs.not_ours is extra" || { k -n drift logs "$job" >&2; fail "drift: the refusal does not name the table"; }
k -n drift logs "$job" | grep -m2 "differs\|not_ours"

step "7. an external ClickHouse lost while 0001 is started: exit 4, failed at once"
deploy_ch ext-lost "$password" /keeper_map
install_external lost ext-lost "$password"
started=
for _ in $(seq 1500); do
  n=$(k -n ext-lost exec ch-0 -- clickhouse-client -u fusescope --password "$password" -q \
    "SELECT count() FROM fusescope_schema.migrations WHERE state = 'started'" 2>/dev/null || true)
  [ "$n" = 1 ] && { started=$(date -u +%T.%N | cut -c1-12); break; }
  sleep 0.2
done
[ -n "$started" ] || fail "lost: 0001 was never seen started"
victim=$(k -n ext-lost get pod ch-0 -o jsonpath='{.metadata.uid}')
k -n ext-lost delete pod ch-0 --grace-period=0 --force >/dev/null 2>&1
deleted=$(date -u +%T.%N | cut -c1-12)
job=$(schema_job lost)
migrator_pod=$(k -n lost get pods -l "job-name=${job#job.batch/}" -o name)
wait_failed_at_once lost "$job" 4
k -n lost get "$migrator_pod" >/dev/null || fail "lost: the migrator's pod is gone: the exit would not be its own"
echo "$started  0001 seen started (fusescope_schema.migrations on ext-lost/ch-0)"
echo "$deleted  deleted ClickHouse pod ext-lost/ch-0, uid $victim (the migrator's pod, lost/${migrator_pod#pod/}, untouched)"
echo "          $migrator_pod exited 4; the Job failed by its podFailurePolicy. Its last lines:"
k -n lost logs "$migrator_pod" | tail -3 | sed 's/^/          /'

step "8. a second upgrade while 0001 is started: serialized by the lease"
h upgrade -i overlap charts/fusescope -n overlap --create-namespace --wait=false >/dev/null
chi=chi-overlap-clickhouse-cluster-0-0-0
started=
for _ in $(seq 3000); do
  n=$(k -n overlap exec "$chi" -c clickhouse -- clickhouse-client -u admin --password 27ff0399-0d3a-4bd8-919d-17c2181e6fb9 -q \
    "SELECT count() FROM fusescope_schema.migrations WHERE state = 'started'" 2>/dev/null || true)
  [ "$n" = 1 ] && { started=1; break; }
  sleep 0.2
done
[ -n "$started" ] || fail "overlap: 0001 was never seen started"
first=$(schema_job overlap)
h upgrade overlap charts/fusescope -n overlap --reuse-values --set telemetryStoreMigrator.resources.limits.memory=256Mi --wait=false >/dev/null
second=$(next_job overlap "$first")
echo "0001 started under $first; upgraded: $second created while it runs"
wait_job overlap "$first"
expect_logs overlap "$first" "starting point: empty" "applied 0001 base" >/dev/null
wait_job overlap "$second"
logs=$(expect_logs overlap "$second" "starting point: managed" "up to date")
grep -q "applied" <<<"$logs" && fail "overlap: the second Job applied a migration too"
done_rows=$(k -n overlap exec "$chi" -c clickhouse -- clickhouse-client -u admin --password 27ff0399-0d3a-4bd8-919d-17c2181e6fb9 -q \
  "SELECT count() FROM fusescope_schema.migrations WHERE state = 'done'")
[ "$done_rows" = 1 ] || fail "overlap: $done_rows done rows, want 1"
echo "$first finished 0001 uninterrupted; $second waited for the lease, then up to date"

printf '\nall fusescope-schema chart tests passed\n'
