#!/bin/sh
# Checks the fusescope-parity chart: it lints strictly and renders valid
# Kubernetes objects for every values file under ci/; the image is pulled by
# digest only; each role's RBAC is exactly what it needs, in the namespace it
# needs it; every pod is hardened and mounts only its own credentials; the
# hourly round never overlaps the daily one; each workload reaches only its
# own destinations; and the releases it must refuse fail to render.
#
# usage: scripts/fusescope-parity-chart-check.sh
set -eu
chart=${CHART:-charts/fusescope-parity}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
staging="$chart/ci/staging-values.yaml"

check() {
    python3 - "$1" "$chart/values.yaml" "$2" <<'PY'
import sys, yaml
path, defaults, name = sys.argv[1], sys.argv[2], sys.argv[3]
docs = [d for d in yaml.safe_load_all(open(path)) if d]
label = name.rsplit("/", 1)[-1]
fail = lambda why: sys.exit(f"chart with {label}: {why}")
release, keys = "parity", "parity-run-keys"
def merge(base, over):
    for k, v in over.items():
        base[k] = merge(base.get(k, {}), v) if isinstance(v, dict) and isinstance(base.get(k), dict) else v
    return base
values = merge(yaml.safe_load(open(defaults)), yaml.safe_load(open(name)))
margin = values["marginSeconds"]
image = f"{values['image']['repository']}@{values['image']['digest']}"
group = values["oncall"]["group"]
proxied = bool(values.get("proxy", {}).get("url"))

if any(d["kind"] in ("ClusterRole", "ClusterRoleBinding") for d in docs):
    fail("a cluster-wide grant")
by = lambda kind: {(d["metadata"].get("namespace", release), d["metadata"]["name"]): d for d in docs if d["kind"] == kind}
roles, bindings = by("Role"), by("RoleBinding")
sa = lambda n: {"kind": "ServiceAccount", "name": f"check-{n}", "namespace": release}
oncall = {"kind": "Group", "apiGroup": "rbac.authorization.k8s.io", "name": group}
want = {
    (keys, "check-run-keys-writer"): ([{"apiGroups": [""], "resources": ["secrets"], "verbs": ["create"]}], sa("run")),
    (keys, "check-run-keys-cleanup"): ([{"apiGroups": [""], "resources": ["secrets"], "verbs": ["list", "delete"]}], sa("cleanup")),
    (keys, "check-run-keys-oncall"): ([{"apiGroups": [""], "resources": ["secrets"], "verbs": ["get"]}], oncall),
    (release, "check-investigate-oncall"): ([
        {"apiGroups": ["apps"], "resources": ["statefulsets/scale"], "resourceNames": ["check-investigate"], "verbs": ["get", "patch"]},
        {"apiGroups": [""], "resources": ["pods"], "resourceNames": ["check-investigate-0"], "verbs": ["get"]},
        {"apiGroups": [""], "resources": ["pods/exec"], "resourceNames": ["check-investigate-0"], "verbs": ["create"]},
    ], oncall),
}
if set(roles) != set(want) or set(bindings) != set(want):
    fail(f"roles {sorted(roles)}, bindings {sorted(bindings)}")
for key, (rules, subject) in want.items():
    if roles[key]["rules"] != rules:
        fail(f"{key} grants {roles[key]['rules']}")
    b = bindings[key]
    if b["subjects"] != [subject] or b["roleRef"] != {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": key[1]}:
        fail(f"{key} binds {b['subjects']} to {b['roleRef']}")
if any(s.get("name") == "check-investigate" for b in bindings.values() for s in b["subjects"]):
    fail("the investigation's ServiceAccount is granted something")

pods = {}
for d in docs:
    if d["kind"] == "CronJob":
        pods[d["metadata"]["name"]] = d["spec"]["jobTemplate"]["spec"]["template"]
    elif d["kind"] == "StatefulSet":
        pods[d["metadata"]["name"]] = d["spec"]["template"]
if set(pods) != {"check-run-hourly", "check-run-daily", "check-cleanup", "check-investigate"}:
    fail(f"workloads {sorted(pods)}")
mounts = {
    "run": {"settings", "tenants", "engine-client", "clickhouse", "pushgateway", "prometheus", "reports"},
    "cleanup": {"settings"},
    "investigate": {"settings", "tenants", "engine-client", "clickhouse", "prometheus", "audit"},
}
for name, template in pods.items():
    component = template["metadata"]["labels"]["app.kubernetes.io/component"]
    pod = template["spec"]
    if pod["serviceAccountName"] != f"check-{component}":
        fail(f"{name} runs as {pod['serviceAccountName']}")
    sc = pod["securityContext"]
    if not sc.get("runAsNonRoot") or sc.get("seccompProfile") != {"type": "RuntimeDefault"}:
        fail(f"{name} pod security {sc}")
    if any(pod.get(k) for k in ("hostNetwork", "hostPID", "hostIPC")):
        fail(f"{name} shares the host")
    if len(pod["containers"]) != 1 or pod.get("initContainers"):
        fail(f"{name} runs more than the parity")
    c = pod["containers"][0]
    if c["image"] != image:
        fail(f"{name} pulls {c['image']}, not {image}")
    csc = c["securityContext"]
    if csc != {"readOnlyRootFilesystem": True, "allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}}:
        fail(f"{name} container security {csc}")
    got = {m["name"] for m in c["volumeMounts"]}
    if got != mounts[component] or {v["name"] for v in pod["volumes"]} != got:
        fail(f"{name} mounts {sorted(got)}")
    if any(not m.get("readOnly") for m in c["volumeMounts"] if m["name"] != "reports"):
        fail(f"{name} mounts a credential writable")
    env = {e["name"]: e.get("value") for e in c.get("env", [])}
    if env.get("PARITY_IMAGE_DIGEST") != values["image"]["digest"]:
        fail(f"{name} reports digest {env.get('PARITY_IMAGE_DIGEST')}")
    want_proxy = proxied and component != "cleanup"
    if ("HTTPS_PROXY" in env) != want_proxy:
        fail(f"{name} proxy env {env}")
    if want_proxy and not {".svc", ".cluster.local", "fusescope-engine-flight.fusescope.svc", "pushgateway.monitoring.svc"} <= set(env["NO_PROXY"].split(",")):
        fail(f"{name} sends in-cluster calls to the proxy: {env['NO_PROXY']}")
    args = c["args"]
    expected = {"run": "run", "cleanup": "cleanup", "investigate": "wait"}[component]
    if args[0] != expected:
        fail(f"{name} runs {args}")

sts = next(d for d in docs if d["kind"] == "StatefulSet")
if sts["spec"]["replicas"] != 0 or sts["metadata"]["name"] != "check-investigate":
    fail("the investigation pod is not held at zero under its granted name")

def span(job):
    return -(-(job["startingDeadlineSeconds"] + job["jobTemplate"]["spec"]["activeDeadlineSeconds"] + margin) // 60)
crons = {d["metadata"]["name"]: d["spec"] for d in docs if d["kind"] == "CronJob"}
for n, spec in crons.items():
    if spec["concurrencyPolicy"] != "Forbid" or spec["timeZone"] != "Etc/UTC" or spec["jobTemplate"]["spec"]["backoffLimit"] != 0:
        fail(f"{n} schedule policy {spec}")
hourly, daily = crons["check-run-hourly"], crons["check-run-daily"]
hm, hours = hourly["schedule"].split()[:2]
dm, dh = (int(x) for x in daily["schedule"].split()[:2])
hs, ds = span(hourly), span(daily)
day = 1440
busy = {(dh * 60 + dm + i) % day for i in range(ds)}
for h in range(24):
    run = {(h * 60 + int(hm) + i) % day for i in range(hs)}
    if (str(h) in hours.split(",")) == bool(run & busy):
        fail(f"hour {h} is {'scheduled' if str(h) in hours.split(',') else 'skipped'} against the daily round")
for key in ("hourly", "daily"):
    if crons[f"check-run-{key}"]["jobTemplate"]["spec"]["activeDeadlineSeconds"] < values["rounds"][key]["budgetSeconds"] + margin:
        fail(f"the {key} round may be killed inside its budget")

reach = {
    "run": ["dns", "apiServer", "engine", "clickhouse", "prometheus", "pushgateway"] + (["proxy"] if proxied else ["bucket", "sts"]),
    "cleanup": ["dns", "apiServer"],
    "investigate": ["dns", "engine", "clickhouse", "prometheus", "audit"] + (["proxy"] if proxied else ["bucket", "sts", "idp"]),
}
policies = {d["metadata"]["labels"]["app.kubernetes.io/component"]: d["spec"] for d in docs if d["kind"] == "NetworkPolicy"}
if set(policies) != set(reach):
    fail(f"policies {sorted(policies)}")
for component, spec in policies.items():
    if spec["policyTypes"] != ["Ingress", "Egress"] or spec.get("ingress"):
        fail(f"{component} accepts ingress")
    if spec["podSelector"]["matchLabels"]["app.kubernetes.io/component"] != component:
        fail(f"{component} policy selects {spec['podSelector']}")
    expected = [r for dest in reach[component] for r in values["egress"][dest]]
    if spec["egress"] != expected:
        fail(f"{component} reaches {spec['egress']}")
    for rule in spec["egress"]:
        if not rule.get("to") or not rule.get("ports"):
            fail(f"{component} has an open egress rule")
        if any(p.get("ipBlock", {}).get("cidr", "").endswith("/0") for p in rule["to"]):
            fail(f"{component} reaches every address")

settings = next(d for d in docs if d["kind"] == "ConfigMap")["data"]
for key in ("hourly.yaml", "daily.yaml", "investigate.yaml"):
    s = yaml.safe_load(settings[key])
    if s["credentials"]["clickhouse_dsn_file"] != "/etc/parity/clickhouse/dsn" or "dsn" in s["clickhouse"].get("clickhouse", {}):
        fail(f"{key} reads the DSN from {s['clickhouse']}")
    if s["secret"]["namespace"] != keys:
        fail(f"{key} writes run keys to {s['secret']['namespace']}")
for key in ("hourly", "daily"):
    if yaml.safe_load(settings[f"{key}.yaml"])["round"]["budget"] != f"{values['rounds'][key]['budgetSeconds']}s":
        fail(f"{key}.yaml carries another budget")
if "round" in yaml.safe_load(settings["investigate.yaml"]):
    fail("the investigation's settings carry a round's bounds")
PY
}

for values in "$chart"/ci/*-values.yaml; do
    name=$(basename "$values")
    helm lint --strict "$chart" -f "$values" >/dev/null
    helm template check "$chart" -f "$values" --namespace parity > "$work/$name"
    kubeconform -strict -summary -kubernetes-version 1.30.0 "$work/$name"
    check "$work/$name" "$values"
    echo "chart with $name: lints, renders valid objects, exact RBAC, hardened pods with only their mounts, rounds apart, egress by workload"
done

# The window both ways round the daily round, round midnight, and at its edges:
# an hourly round ending as the daily one starts, or starting as it ends.
for times in 50:3:0 0:0:30 59:23:0 30:0:15 20:3:0 15:3:0; do
    hm=${times%%:*} rest=${times#*:}
    dh=${rest%%:*} dm=${rest#*:}
    python3 - "$staging" "$work/timed.yaml" "$hm" "$dh" "$dm" <<'PY'
import sys, yaml
base = yaml.safe_load(open(sys.argv[1]))
base["rounds"] = {"hourly": {"minute": int(sys.argv[3])}, "daily": {"hour": int(sys.argv[4]), "minute": int(sys.argv[5])}}
yaml.safe_dump(base, open(sys.argv[2], "w"))
PY
    helm template check "$chart" -f "$work/timed.yaml" --namespace parity > "$work/timed-render.yaml"
    check "$work/timed-render.yaml" "$work/timed.yaml"
done
echo "chart keeps the hourly round clear of the daily one on both sides and round midnight"

cat > "$work/proxy-values.yaml" <<'EOF'
proxy:
  url: https://egress-proxy.example.com:3128
egress:
  proxy:
    - to:
        - ipBlock: {cidr: 10.0.32.0/28}
      ports:
        - {protocol: TCP, port: 3128}
EOF
python3 - "$staging" "$work/proxy-values.yaml" "$work/proxied.yaml" <<'PY'
import sys, yaml
base, overlay = yaml.safe_load(open(sys.argv[1])), yaml.safe_load(open(sys.argv[2]))
base["proxy"] = overlay["proxy"]
base["egress"]["proxy"] = overlay["egress"]["proxy"]
for dest in ("bucket", "sts", "idp"):
    base["egress"][dest] = []
yaml.safe_dump(base, open(sys.argv[3], "w"))
PY
helm template check "$chart" -f "$work/proxied.yaml" --namespace parity > "$work/proxied-render.yaml"
kubeconform -strict -summary -kubernetes-version 1.30.0 "$work/proxied-render.yaml"
check "$work/proxied-render.yaml" "$work/proxied.yaml"
echo "chart through a proxy: bucket, STS and IdP through it, in-cluster calls direct, the cleanup without it"

refuse() {
    if helm template check "$chart" --namespace parity "$@" >/dev/null 2>"$work/err"; then
        echo "the chart rendered what it must refuse: $*" >&2
        exit 1
    fi
}
refuse
refuse -f "$staging" --set image.digest=
refuse -f "$staging" --set image.digest=sha256:abc
refuse -f "$staging" --set image.digest=0000000000000000000000000000000000000000000000000000000000000000
refuse -f "$staging" --set image.tag=latest
refuse -f "$staging" --set image.tag=
refuse -f "$staging" --set image.repository=
refuse -f "$staging" --set secrets.audit=parity-pushgateway
refuse -f "$staging" --set secrets.clickhouse=
refuse -f "$staging" --set tenants.configMap=
refuse -f "$staging" --set oncall.group=
refuse -f "$staging" --set runKeys.namespace=parity
refuse -f "$staging" --set rounds.hourly.activeDeadlineSeconds=1499
refuse -f "$staging" --set rounds.daily.budgetSeconds=7000
refuse -f "$staging" --set rounds.hourly.round.budget=1h
refuse -f "$staging" --set rounds.daily.activeDeadlineSeconds=86000
refuse -f "$staging" --set 'egress.apiServer[0].ports=null'
refuse -f "$staging" --set 'egress.apiServer[0].to=null'
refuse -f "$staging" --set 'egress.bucket[0].to[0].ipBlock.cidr=0.0.0.0/0'
refuse -f "$staging" --set 'egress.idp[0].to[0].ipBlock.cidr=::/0'
refuse -f "$staging" --set egress.audit=null
refuse -f "$staging" --set proxy.url=https://egress-proxy.example.com:3128
refuse -f "$staging" --set unknown=1
refuse -f "$staging" --set rounds.daily.hour=24
refuse -f "$staging" --set rounds.hourly.minute=60
refuse -f "$staging" --set marginSeconds=-1
refuse -f "$staging" --set pushgateway.url=http://pushgateway.monitoring.svc:9091
refuse -f "$staging" --set investigate.issuer=http://idp.example.com
refuse -f "$staging" --set runKeys.namespace=Parity_Keys
refuse -f "$staging" --set build.backendCommit=1234
helm template check "$chart" --namespace parity -f "$staging" --set rounds.hourly.activeDeadlineSeconds=1500 >/dev/null
echo "chart refuses a release without its image digest, with a tag, a malformed digest or no repository; Secrets missing or alike; no tenants or on-call group; run keys in the release's namespace; a deadline inside its budget plus margin; a budget set twice; a daily round that leaves no hour; an egress rule without peers or ports, to every address, or missing for a workload; an unknown value, a time out of range, a plain-HTTP endpoint or a malformed namespace"
