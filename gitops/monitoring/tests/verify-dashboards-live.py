#!/usr/bin/env python3
"""Live checks for the custom Grafana dashboards against the running cluster.

Run it after a dashboard, scrape or Alloy change has been reconciled by Flux:

    python3 gitops/monitoring/tests/verify-dashboards-live.py
    python3 gitops/monitoring/tests/verify-dashboards-live.py --grafana --spoof-url https://taskflow.example

What it does (read-only, except the opt-in WAF spoof request):

1. Query sweep: runs every MetricsQL/LogQL target and annotation of every
   dashboard JSON in this repo against VMSingle and Loki, with Grafana's macros
   and the dashboards' default variable values substituted. ERROR means Grafana
   would show a query error; EMPTY means "No data" right now (often legitimate,
   e.g. no WAF detections or no 5xx, so it is reported, not failed).
2. Targeted checks for the fixes in the dashboard review: label sources
   (honorLabels, metrics_path, backend_type), deduplication, cert-manager expiry
   against the Certificate objects, Kyverno rule counts against the policies,
   threshold assumptions (VMSingle PVC name, Loki stream limit), Alloy health,
   WAF rule_id label hygiene and the abuseipdb-sync version.
3. --grafana: Grafana has provisioned every repo dashboard (uid, title, folder)
   and serves the same queries as the repo JSON (the sidecar picked it up).
4. --spoof-url: sends one request to a non-existent path on the public site
   with a fake "Messages: [id ...]" header and spoofed User-Agent, then checks
   that the WAF dashboards and Alloy metrics do NOT count it as a detection.

Needs python3 (stdlib only) and kubectl with access to the cluster; it opens
temporary port-forwards to VMSingle, Loki and (with --grafana) Grafana. Pass
--vm-url/--loki-url/--grafana-url to use existing endpoints instead, and
--no-kubectl to skip the checks that read Kubernetes objects.

Exit status: 1 if any check FAILs or any dashboard query ERRORs, else 0.
"""

import argparse
import base64
import contextlib
import datetime
import hashlib
import json
import math
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
DASHBOARD_DIRS = [
    REPO / "gitops/monitoring/app/dashboards",
    REPO / "gitops/monitoring/logging/dashboards",
]
WAF_MANIFESTS = sorted((REPO / "gitops/apps/taskflow").glob("*waf*.yaml"))

# Datasource defaults, as provisioned in gitops/monitoring/platform/release.yaml
# (VictoriaMetrics, jsonData.timeInterval) and logging/loki-datasource.yaml (loki).
SCRAPE_INTERVAL_S = 30
VM_UIDS = {"VictoriaMetrics", "${datasource}", "$datasource"}
LOKI_UIDS = {"loki", "${lokiDatasource}", "$lokiDatasource"}
# Panel width in pixels Grafana typically renders with; drives $__interval.
MAX_DATA_POINTS = 1000

SPOOF_RULE_ID = "987654321"

COLORS = {"PASS": "32", "FAIL": "31", "ERROR": "31", "WARN": "33", "EMPTY": "33", "SKIP": "90", "OK": "32", "INFO": "36"}


class Report:
    def __init__(self, color):
        self.color = color
        self.rows = []

    def add(self, section, status, name, detail=""):
        self.rows.append((section, status, name, detail))
        tag = f"{status:<5}"
        if self.color:
            tag = f"\033[{COLORS.get(status, '0')}m{tag}\033[0m"
        print(f"  {tag} {name}" + (f" - {detail}" if detail else ""), flush=True)

    def count(self, status):
        return sum(1 for r in self.rows if r[1] == status)


def section(title):
    print(f"\n== {title}", flush=True)


# --- HTTP and port-forward helpers -------------------------------------------

def http_json(url, params=None, headers=None, timeout=60):
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as err:
        body = err.read().decode(errors="replace")
        try:
            data = json.loads(body)
        except ValueError:
            data = {"status": "error", "error": body.strip()[:500] or str(err)}
        data.setdefault("status", "error")
        data.setdefault("error", str(err))
        return data


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@contextlib.contextmanager
def port_forward(namespace, target, remote_port, path=""):
    port = free_port()
    proc = subprocess.Popen(
        ["kubectl", "-n", namespace, "port-forward", target, f"{port}:{remote_port}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.time() + 30
        while time.time() < deadline:
            if proc.poll() is not None:
                raise SystemExit(f"kubectl port-forward {namespace}/{target} failed: {proc.stderr.read().strip()}")
            with contextlib.suppress(OSError), socket.create_connection(("127.0.0.1", port), timeout=1):
                break
            time.sleep(0.3)
        else:
            raise SystemExit(f"kubectl port-forward {namespace}/{target} did not become ready")
        yield f"http://127.0.0.1:{port}{path}"
    finally:
        proc.terminate()
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.wait(timeout=5)


def kubectl_json(*args):
    out = subprocess.run(["kubectl", *args, "-o", "json"], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip())
    return json.loads(out.stdout)


# --- Datasource clients -------------------------------------------------------

class VM:
    def __init__(self, base):
        self.base = base.rstrip("/")

    def instant(self, query, at=None):
        params = {"query": query}
        if at:
            params["time"] = f"{at:.3f}"
        return http_json(f"{self.base}/api/v1/query", params)

    def range(self, query, start, end, step):
        return http_json(f"{self.base}/api/v1/query_range",
                         {"query": query, "start": f"{start:.3f}", "end": f"{end:.3f}", "step": f"{step}s"})

    def vector(self, query):
        """Instant query as [(labels, value)]; raises on query errors."""
        data = self.instant(query)
        if data.get("status") != "success":
            raise RuntimeError(f"{query}: {data.get('error')}")
        return [(r["metric"], float(r["value"][1])) for r in data["data"]["result"]]


class Loki:
    def __init__(self, base):
        self.base = base.rstrip("/")

    def range(self, query, start, end, step, limit=20):
        return http_json(f"{self.base}/loki/api/v1/query_range", {
            "query": query, "start": str(int(start * 1e9)), "end": str(int(end * 1e9)),
            "step": f"{step}s", "limit": str(limit), "direction": "backward"})

    def instant(self, query, at):
        return http_json(f"{self.base}/loki/api/v1/query", {"query": query, "time": str(int(at * 1e9)), "limit": "20"})

    def label_values(self, label, start, end):
        data = http_json(f"{self.base}/loki/api/v1/label/{label}/values",
                         {"start": str(int(start * 1e9)), "end": str(int(end * 1e9))})
        return data.get("data") or []

    def total(self, query, at):
        data = self.instant(query, at)
        if data.get("status") != "success":
            raise RuntimeError(f"{query}: {data.get('error')}")
        return sum(float(r["value"][1]) for r in data["data"]["result"])


# --- Dashboard query sweep ----------------------------------------------------

def parse_duration(text):
    m = re.fullmatch(r"(\d+)(ms|s|m|h|d)", str(text or "").strip())
    if not m:
        return 0
    return int(m.group(1)) * {"ms": 0.001, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]


def all_panels(panels):
    for panel in panels or []:
        yield panel
        yield from all_panels(panel.get("panels"))


def variable_values(dashboard):
    """Default value of every template variable, formatted like Grafana does for =~."""
    values = {}
    for var in dashboard.get("templating", {}).get("list", []):
        name, kind = var.get("name"), var.get("type")
        if kind == "datasource":
            continue
        current = (var.get("current") or {}).get("value")
        selected = current if isinstance(current, list) else ([current] if current not in (None, "") else [])
        if (not selected and var.get("includeAll")) or "$__all" in selected:
            values[name] = var.get("allValue") or ".*"
        elif selected:
            values[name] = selected[0] if len(selected) == 1 else "(" + "|".join(map(str, selected)) + ")"
        elif kind == "textbox":
            values[name] = var.get("query", "")
        elif var.get("options"):
            values[name] = var["options"][0].get("value", "")
        else:
            values[name] = ".*"
    return values


def expand(expr, variables, interval_s, range_s):
    rate = max(interval_s + SCRAPE_INTERVAL_S, 4 * SCRAPE_INTERVAL_S)
    builtins = {
        "__rate_interval_ms": str(int(rate * 1000)), "__rate_interval": f"{int(rate)}s",
        "__interval_ms": str(int(interval_s * 1000)), "__interval": f"{int(interval_s)}s",
        "__auto": f"{int(interval_s)}s", "__range_s": str(int(range_s)),
        "__range_ms": str(int(range_s * 1000)), "__range": f"{int(range_s)}s",
    }

    def repl(m):
        name = m.group(1) or m.group(2)
        if name in builtins:
            return builtins[name]
        if name in variables:
            return str(variables[name])
        return m.group(0)

    # ${var}, ${var:format} and $var; unknown names (e.g. label_replace's $1) stay as they are.
    return re.sub(r"\$\{(\w+)(?::\w+)?\}|\$(\w+)", repl, expr)


def target_kind(target, panel):
    ds = target.get("datasource") or panel.get("datasource") or {}
    uid = ds.get("uid", "") if isinstance(ds, dict) else str(ds)
    dtype = ds.get("type", "") if isinstance(ds, dict) else ""
    if uid in LOKI_UIDS or dtype == "loki":
        return "loki"
    if uid in VM_UIDS or dtype in ("prometheus", "victoriametrics-metrics-datasource"):
        return "vm"
    return None


def classify(data):
    if data.get("status") != "success":
        return "ERROR", str(data.get("error") or data.get("message") or data)[:300]
    result = data.get("data", {}).get("result") or []
    if not result:
        return "EMPTY", ""
    if data["data"].get("resultType") == "streams":
        lines = sum(len(s.get("values", [])) for s in result)
        return "OK", f"{len(result)} stream(s), {lines} line(s)"
    return "OK", f"{len(result)} series"


def sweep(report, vm, loki, range_s, now, verbose):
    dashboards = sorted(p for d in DASHBOARD_DIRS for p in d.glob("*.json"))
    for path in dashboards:
        dashboard = json.loads(path.read_text())
        section(f"Query sweep: {dashboard.get('title')} ({path.relative_to(REPO)})")
        variables = variable_values(dashboard)
        items = []
        for panel in all_panels(dashboard.get("panels")):
            for target in panel.get("targets") or []:
                if target.get("expr"):
                    items.append((f"#{panel.get('id')} {panel.get('title', '')} [{target.get('refId', '?')}]", panel, target))
        for ann in dashboard.get("annotations", {}).get("list", []):
            if ann.get("expr"):
                items.append((f"annotation {ann.get('name')}", ann, ann))
        counts = {"OK": 0, "EMPTY": 0, "ERROR": 0}
        for name, panel, target in items:
            kind = target_kind(target, panel)
            if kind is None or (kind == "loki" and not loki) or (kind == "vm" and not vm):
                report.add("sweep", "SKIP", name, "datasource not available")
                continue
            min_interval = parse_duration(panel.get("interval") or target.get("interval"))
            interval = max(SCRAPE_INTERVAL_S, min_interval, math.ceil(range_s / MAX_DATA_POINTS))
            expr = expand(target["expr"], variables, interval, range_s)
            start = now - range_s
            if kind == "vm":
                instant = target.get("instant") and not target.get("range")
                data = vm.instant(expr, now) if instant else vm.range(expr, start, now, interval)
            else:
                instant = target.get("queryType") == "instant"
                data = loki.instant(expr, now) if instant else loki.range(expr, start, now, interval)
            status, detail = classify(data)
            counts[status] += 1
            if status != "OK" or verbose:
                report.add("sweep", status, name, detail + (f"\n          {expr}" if status == "ERROR" or verbose else ""))
        print(f"  -> {counts['OK']} with data, {counts['EMPTY']} empty, {counts['ERROR']} errors")
        report.rows.append(("sweep-summary", "INFO", dashboard.get("title"), json.dumps(counts)))


# --- Targeted checks ----------------------------------------------------------

def check(report, name, fn):
    try:
        status, detail = fn()
    except Exception as err:  # a broken check must not hide the others
        status, detail = "FAIL", f"check raised: {err}"
    report.add("checks", status, name, detail)


def fmt_labels(rows, key):
    return ", ".join(sorted(f"{r[0].get(key, '')}={r[1]:g}" for r in rows))


def repo_custom_rule_ids():
    ids = set()
    for path in WAF_MANIFESTS:
        ids.update(re.findall(r"\bid:\s*'?\"?(\d+)", path.read_text()))
    return ids


def targeted_checks(report, vm, loki, args, now):
    section("Targeted checks")

    def targets_down():
        rows = vm.vector('up{namespace=~"taskflow|falco|kyverno|trivy-system|cert-manager|monitoring|abuseipdb|kube-system"} == 0')
        if not rows:
            return "PASS", "every scrape target in the dashboards' namespaces is up"
        return "WARN", "down: " + ", ".join(sorted({f"{r[0].get('job')}/{r[0].get('pod', r[0].get('instance'))}" for r in rows}))
    check(report, "scrape targets up", targets_down)

    def honor_labels(metric, own_ns):
        def fn():
            rows = vm.vector(f"count by (namespace) ({metric})")
            if not rows:
                return "SKIP", f"no {metric} series"
            namespaces = {r[0].get("namespace") for r in rows}
            stale = vm.vector(f'count({metric}{{exported_namespace!=""}})')
            if namespaces == {own_ns}:
                return "FAIL", f"every series has namespace={own_ns}: honorLabels is not applied"
            if stale and stale[0][1] > 0:
                return "WARN", f"{stale[0][1]:g} series still carry exported_namespace (pre-change series; re-run in 5 min)"
            return "PASS", "namespaces: " + ", ".join(sorted(namespaces))
        return fn
    check(report, "Trivy findings keep their own namespace", honor_labels("trivy_image_vulnerabilities", "trivy-system"))
    check(report, "cert-manager certificates keep their own namespace", honor_labels("certmanager_certificate_ready_status", "cert-manager"))

    def cadvisor(ns, container):
        def fn():
            q = f'sum by (pod) (rate(container_cpu_usage_seconds_total{{namespace="{ns}",container="{container}",metrics_path="%s"}}[5m]))'
            if not vm.vector(f'count(container_cpu_usage_seconds_total{{namespace="{ns}",container="{container}"}})'):
                return "SKIP", f"no {ns}/{container} container metrics"
            cad = vm.vector(q % "/metrics/cadvisor")
            res = vm.vector(q % "/metrics/resource")
            if not cad:
                return "FAIL", "no cAdvisor series with metrics_path=/metrics/cadvisor: the CPU panel is empty"
            extra = f"; /metrics/resource duplicates it ({len(res)} pod(s)), so the filter is required" if res else ""
            return "PASS", f"{len(cad)} pod(s) {fmt_labels(cad, 'pod')} cores{extra}"
        return fn
    check(report, "Falco CPU source (cAdvisor only)", cadvisor("falco", "falco"))
    check(report, "Taskflow backend CPU source (cAdvisor only)", cadvisor("taskflow", "backend"))

    def requests_not_limits(ns, container_re):
        def fn():
            if not vm.vector(f'count(kube_pod_container_info{{namespace="{ns}",container=~"{container_re}"}})'):
                return "SKIP", f"no {ns} containers in kube-state-metrics"
            req = vm.vector(f'kube_pod_container_resource_requests{{namespace="{ns}",container=~"{container_re}",resource="cpu"}}')
            lim = vm.vector(f'kube_pod_container_resource_limits{{namespace="{ns}",container=~"{container_re}",resource="cpu"}}')
            if not req:
                return "FAIL", "no CPU request series: the CPU-vs-request panel is empty"
            if lim:
                return "WARN", "a CPU limit is set again; the panel still compares against the request"
            return "PASS", f"{len(req)} container(s) with a CPU request and no CPU limit"
        return fn
    check(report, "Taskflow backend CPU request (panel denominator)", requests_not_limits("taskflow", "backend"))
    check(report, "Kyverno CPU requests (panel denominator)", requests_not_limits("kyverno", "kyverno|controller"))

    def http_buckets():
        if not vm.vector('count(http_server_requests_seconds_count{namespace="taskflow",service="backend"})'):
            return "SKIP", "no backend HTTP metrics"
        rows = vm.vector('count(http_server_requests_seconds_bucket{namespace="taskflow",service="backend"})')
        if rows:
            return "PASS", f"{rows[0][1]:g} bucket series: the p95 series works"
        return "WARN", "no _bucket series: the backend should publish them (MANAGEMENT_METRICS_DISTRIBUTION_PERCENTILESHISTOGRAM_HTTP_SERVER_REQUESTS=true in gitops/apps/taskflow/backend.yaml, after the rollout); mean/max still show"
    check(report, "Taskflow HTTP latency histogram (p95)", http_buckets)

    def pg_backend_type():
        if not vm.vector('count(pg_stat_activity_count{namespace="taskflow"})'):
            return "SKIP", "no postgres_exporter series"
        rows = vm.vector('sum(pg_stat_activity_count{namespace="taskflow",backend_type="client backend"})')
        if not rows:
            return "FAIL", "no backend_type=\"client backend\" series: the connections panel is empty"
        limit = vm.vector('max(pg_settings_max_connections{namespace="taskflow"})')
        return "PASS", f"{rows[0][1]:g} client connections" + (f" of max_connections {limit[0][1]:g}" if limit else "")
    check(report, "PostgreSQL client connections (backend_type label)", pg_backend_type)

    def heap_max():
        if not vm.vector('count(jvm_memory_max_bytes{namespace="taskflow",area="heap"})'):
            return "SKIP", "no JVM metrics"
        rows = vm.vector('max(sum by (pod) (jvm_memory_max_bytes{namespace="taskflow",area="heap"} > 0))')
        return ("PASS", f"heap max {rows[0][1] / 2**20:.0f} MiB per pod") if rows else ("FAIL", "no positive heap max: the max heap series is empty")
    check(report, "JVM heap max (pools reporting -1 excluded)", heap_max)

    def falco_priorities():
        names = ["emergency", "alert", "critical", "error", "warning", "notice", "informational", "debug"]
        rows = vm.vector("sum by (priority) (falcosecurity_falco_rules_matches_total)")
        if not rows:
            return "SKIP", "no Falco rule matches yet"
        bad = [r[0].get("priority") for r in rows if r[0].get("priority") not in {str(i) for i in range(8)}]
        if bad:
            return "FAIL", f"unexpected priority values {bad}: the dashboard maps 0-7 only"
        shown = ", ".join(f"{r[0]['priority']}={names[int(r[0]['priority'])]}:{r[1]:g}" for r in sorted(rows, key=lambda r: r[0]["priority"]))
        return "PASS", f"{shown} (compare with the priorities in Falco's own logs)"
    check(report, "Falco priority values (0 emergency .. 7 debug)", falco_priorities)

    def kyverno_jobs():
        rows = vm.vector("count by (job) (kyverno_policy_changes_total)")
        jobs = {r[0].get("job") for r in rows}
        if not rows:
            return "SKIP", "no kyverno_policy_changes_total series"
        if "admission-controller" not in jobs:
            return "FAIL", f"jobs {sorted(jobs)}: the Policy changes panel filters job=\"admission-controller\""
        return "PASS", f"jobs {sorted(jobs)}"
    check(report, "Kyverno policy-change job label", kyverno_jobs)

    def kyverno_labels():
        if not vm.vector("count(kyverno_policy_results_total)"):
            return "SKIP", "no kyverno_policy_results_total series"
        rows = vm.vector('count(kyverno_policy_results_total{resource_namespace!=""})')
        if rows:
            return "WARN", f"{rows[0][1]:g} series still carry resource_namespace: restart the four Kyverno Deployments so the metricsExposure change applies"
        return "PASS", "policy results carry no resource_namespace (metricsExposure applied)"
    check(report, "Kyverno metric label exposure", kyverno_labels)

    def kyverno_rules():
        rows = vm.vector("count(max by (policy_type, policy_name, rule_name) (kyverno_policy_rule_info_total == 1))")
        shown = int(rows[0][1]) if rows else 0
        if args.no_kubectl:
            return "PASS" if shown else "SKIP", f"dashboard counts {shown} active rules (kubectl skipped)"
        total = 0
        for kind in ("clusterpolicies.kyverno.io", "policies.kyverno.io"):
            with contextlib.suppress(RuntimeError):
                for item in kubectl_json("get", kind, "-A").get("items", []):
                    total += len(item.get("spec", {}).get("rules") or [])
                    total += len((item.get("status", {}).get("autogen") or {}).get("rules") or [])
        if shown == total:
            return "PASS", f"{shown} rules (spec + autogen) on both sides"
        return "WARN", f"dashboard counts {shown}, policies define {total} (spec + autogen); check for duplicate exporters or not-ready rules"
    check(report, "Kyverno active rule count vs policies", kyverno_rules)

    def cert_expiry():
        rows = vm.vector("certmanager_certificate_expiration_timestamp_seconds")
        if not rows:
            return "SKIP", "no cert-manager certificate series"
        zero = [r for r in rows if r[1] == 0]
        if args.no_kubectl:
            return ("WARN", f"{len(zero)} certificate(s) never issued (expiry 0)") if zero else ("PASS", f"{len(rows)} certificate(s), all issued")
        by_key = {(r[0].get("namespace"), r[0].get("name")): r[1] for r in rows}
        mismatches = []
        for item in kubectl_json("get", "certificates.cert-manager.io", "-A").get("items", []):
            key = (item["metadata"]["namespace"], item["metadata"]["name"])
            not_after = item.get("status", {}).get("notAfter")
            if not not_after:
                continue
            expected = datetime.datetime.fromisoformat(not_after.replace("Z", "+00:00")).timestamp()
            got = by_key.get(key)
            if got is None or abs(got - expected) > 1:
                mismatches.append(f"{key[0]}/{key[1]} metric={got} notAfter={not_after}")
        if mismatches:
            return "FAIL", "; ".join(mismatches)
        return "PASS", f"{len(rows)} certificate(s) match status.notAfter" + (f"; {len(zero)} never issued (hidden from expiry panels)" if zero else "")
    check(report, "cert-manager expiry vs Certificate.status.notAfter", cert_expiry)

    def vmsingle_pvc():
        if not vm.vector('count(kubelet_volume_stats_capacity_bytes{namespace="monitoring"})'):
            return "SKIP", "no kubelet volume stats for the monitoring namespace"
        rows = vm.vector('kubelet_volume_stats_capacity_bytes{namespace="monitoring",persistentvolumeclaim=~"vmsingle-.*"}')
        if rows:
            return "PASS", ", ".join(r[0].get("persistentvolumeclaim", "") for r in rows) + " gets the stricter VMSingle thresholds"
        names = [r[0].get("persistentvolumeclaim") for r in vm.vector('kubelet_volume_stats_capacity_bytes{namespace="monitoring"}')]
        return "FAIL", f"no PVC named vmsingle-*; the Monitoring volumes override never applies (PVCs: {names})"
    check(report, "VMSingle PVC name matches the volume override", vmsingle_pvc)

    def loki_streams():
        rows = vm.vector("sum(loki_ingester_memory_streams)")
        if not rows:
            return "SKIP", "no Loki ingester metrics"
        value = rows[0][1]
        return ("PASS" if value < 4000 else "WARN"), f"{value:g} active streams (orange at 4000, Loki rejects new streams above 5000)"
    check(report, "Loki active streams below the limit", loki_streams)

    def loki_discards():
        rows = vm.vector("sum by (reason) (increase_pure(loki_discarded_samples_total[24h])) > 0")
        return ("WARN", "discarded in 24h: " + fmt_labels(rows, "reason")) if rows else ("PASS", "no discarded log lines in 24h")
    check(report, "Loki discarded samples (24h)", loki_discards)

    def alloy_health():
        rows = vm.vector('sum(alloy_component_controller_running_components{health_type!="healthy"})')
        dropped = vm.vector("sum(increase(loki_write_dropped_bytes_total[24h])) > 0")
        if not vm.vector("count(alloy_component_controller_running_components)"):
            return "SKIP", "no Alloy metrics"
        if rows and rows[0][1] > 0:
            return "FAIL", f"{rows[0][1]:g} Alloy component(s) not healthy"
        return ("WARN", f"Alloy dropped {dropped[0][1]:g} bytes in 24h") if dropped else ("PASS", "all Alloy components healthy, nothing dropped in 24h")
    check(report, "Alloy components healthy", alloy_health)

    def cilium_jobs():
        rows = vm.vector('min by (job) (up{job=~"cilium-agent|cilium-operator|hubble"})')
        jobs = {r[0].get("job"): r[1] for r in rows}
        missing = {"cilium-agent", "cilium-operator", "hubble"} - set(jobs)
        down = [j for j, v in jobs.items() if v < 1]
        if missing or down:
            return "WARN", f"missing jobs {sorted(missing)}, down {sorted(down)}"
        return "PASS", "cilium-agent, cilium-operator and hubble are scraped"
    check(report, "Cilium scrape jobs", cilium_jobs)

    def abuseipdb():
        info = vm.vector("abuseipdb_build_info")
        if not info:
            return "SKIP", "abuseipdb-sync not scraped"
        versions = sorted({r[0].get("version", "?") for r in info})
        age = vm.vector("max(abuseipdb_feed_age_seconds)")
        detail = f"version {', '.join(versions)}" + (f", feed age {age[0][1] / 3600:.1f}h" if age else ", feed age not reported yet")
        if any(v.startswith("0.3.1") for v in versions):
            return "WARN", detail + ": pin the 0.3.2 image so feed age survives restarts"
        if age and age[0][1] > 24 * 3600:
            return "WARN", detail + ": older than ABUSEIPDB_MAX_STALE_AGE (24h)"
        return "PASS", detail
    check(report, "abuseipdb-sync version and feed age", abuseipdb)

    def waf_rule_ids():
        allowed = repo_custom_rule_ids()
        metric_ids = {r[0].get("rule_id") for r in vm.vector("count by (rule_id) (loki_process_custom_taskflow_waf_first_rule_total)")}
        loki_ids = set(loki.label_values("rule_id", now - 7 * 86400, now)) if loki else set()
        ids = {i for i in metric_ids | loki_ids if i}
        if not ids:
            return "SKIP", "no WAF detections recorded yet"
        bad = sorted(i for i in ids if not re.fullmatch(r"9\d{5}", i) and i not in allowed)
        if bad:
            return "FAIL", f"rule_id values that are not CRS (9xxxxx) or repo custom rules {sorted(allowed)}: {bad}"
        return "PASS", f"{len(ids)} rule ids, all CRS or repo custom rules"
    check(report, "WAF rule_id labels are real rule ids", waf_rule_ids)

    if loki:
        def loki_streams_present():
            jobs = set(loki.label_values("job", now - 86400, now))
            missing = {"coraza-waf", "hubble-flows", "cloudflare-firewall"} - jobs
            return ("WARN", f"no logs in 24h for job(s) {sorted(missing)}") if missing else ("PASS", "coraza-waf, hubble-flows and cloudflare-firewall logs present")
        check(report, "Loki streams the dashboards read", loki_streams_present)


# --- Grafana provisioning -----------------------------------------------------

def target_fingerprint(dashboard):
    exprs = sorted(t.get("expr", "") for p in all_panels(dashboard.get("panels")) for t in p.get("targets") or [])
    return hashlib.sha256("\n".join(exprs).encode()).hexdigest()[:12]


def kustomize_folders():
    folders = {}
    for d in DASHBOARD_DIRS:
        text = (d / "kustomization.yaml").read_text()
        for block in text.split("- name: ")[1:]:
            file_m = re.search(r"files:\s*\n\s*-\s*(\S+)", block)
            folder_m = re.search(r"grafana_folder:\s*(\S+)", block)
            if file_m and folder_m:
                folders[file_m.group(1)] = folder_m.group(1)
    return folders


def grafana_checks(report, base, auth):
    section("Grafana provisioning")
    headers = {"Authorization": auth}
    found = http_json(f"{base}/api/search", {"type": "dash-db", "limit": "5000"}, headers)
    if isinstance(found, dict):
        report.add("grafana", "FAIL", "list dashboards", str(found.get("message") or found.get("error")))
        return
    by_uid = {d["uid"]: d for d in found}
    folders = kustomize_folders()
    for d in DASHBOARD_DIRS:
        for path in sorted(d.glob("*.json")):
            repo = json.loads(path.read_text())
            uid = repo.get("uid")
            name = f"{repo.get('title')} ({uid})"
            live = by_uid.get(uid)
            if not live:
                report.add("grafana", "FAIL", name, "not provisioned")
                continue
            problems = []
            if live.get("title") != repo.get("title"):
                problems.append(f"title {live.get('title')!r}")
            want_folder = folders.get(path.name)
            if want_folder and live.get("folderTitle") != want_folder:
                problems.append(f"folder {live.get('folderTitle')!r}, expected {want_folder!r}")
            served = http_json(f"{base}/api/dashboards/uid/{uid}", headers=headers).get("dashboard") or {}
            if target_fingerprint(served) != target_fingerprint(repo):
                problems.append("queries differ from the repo JSON (sidecar not reloaded yet, or an edited copy)")
            report.add("grafana", "FAIL" if problems else "PASS", name, "; ".join(problems) or "provisioned, queries match the repo")


# --- WAF spoof check ------------------------------------------------------------

def spoof_check(report, vm, loki, site, wait_s):
    section("WAF detection spoofing")
    marker = f"dashboard-spoof-check-{int(time.time())}"
    url = site.rstrip("/") + "/" + marker
    req = urllib.request.Request(url, headers={
        "Messages": f'[id "{SPOOF_RULE_ID}"] [msg "dashboard spoof check"] [tag "paranoia-level/4"]',
        "Stopwatch": "1 1; combined=999999999999, p1=1",
        "User-Agent": f'verify-dashboards-live combined=999999999999 [msg "spoof"] [tag "paranoia-level/4"] {marker}',
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            code = resp.status
    except urllib.error.HTTPError as err:
        code = err.code
    except urllib.error.URLError as err:
        report.add("spoof", "FAIL", "send spoof request", str(err))
        return
    report.add("spoof", "INFO", "sent spoof request", f"GET {url} -> HTTP {code}")
    seen = False
    deadline = time.time() + wait_s
    while time.time() < deadline:
        now = time.time()
        if loki.total(f'sum(count_over_time({{job="coraza-waf"}} |= "{marker}" [15m]))', now) > 0:
            seen = True
            break
        time.sleep(10)
    if not seen:
        report.add("spoof", "WARN", "spoof request logged", f"no WAF log line with {marker} within {wait_s}s; result inconclusive")
        return
    time.sleep(2 * 60)  # let Alloy's metrics be scraped (60s interval) before checking them
    now = time.time()
    detections = loki.total(f'sum(count_over_time({{job="coraza-waf"}} |= "}},\\"messages\\":[{{" |= "{marker}" [20m]))', now)
    labelled = loki.total(f'sum(count_over_time({{job="coraza-waf", rule_id="{SPOOF_RULE_ID}"}} [20m]))', now)
    series = vm.vector(f'loki_process_custom_taskflow_waf_first_rule_total{{rule_id="{SPOOF_RULE_ID}"}}')
    report.add("spoof", "FAIL" if detections else "PASS", "dashboards do not count the spoof as a detection",
               f"{detections:g} detection-bearing record(s) with the marker")
    report.add("spoof", "FAIL" if labelled or series else "PASS", f"no rule_id={SPOOF_RULE_ID} label in Loki or Alloy metrics",
               f"loki lines {labelled:g}, metric series {len(series)}")


# --- main -----------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vm-url", help="VMSingle base URL incl. /vmsingle (default: port-forward)")
    ap.add_argument("--loki-url", help="Loki base URL (default: port-forward)")
    ap.add_argument("--grafana", action="store_true", help="also check Grafana provisioning (port-forward + admin secret)")
    ap.add_argument("--grafana-url", help="Grafana base URL; auth from GRAFANA_TOKEN, GRAFANA_BASIC_AUTH=user:pass or the admin secret")
    ap.add_argument("--spoof-url", help="public site URL to send one spoofed request to (opt-in)")
    ap.add_argument("--spoof-wait", type=int, default=300, help="seconds to wait for the spoof request's WAF log line")
    ap.add_argument("--range", default="6h", help="time range for the query sweep (default 6h)")
    ap.add_argument("--no-kubectl", action="store_true", help="skip checks that read Kubernetes objects")
    ap.add_argument("--skip-sweep", action="store_true", help="skip the per-panel query sweep")
    ap.add_argument("--verbose", action="store_true", help="print every query, including those with data")
    ap.add_argument("--no-color", action="store_true")
    args = ap.parse_args()

    range_s = parse_duration(args.range)
    if not range_s:
        ap.error(f"invalid --range {args.range!r}")
    if not args.no_kubectl or not (args.vm_url and args.loki_url):
        if subprocess.run(["kubectl", "version", "--client"], capture_output=True).returncode != 0:
            ap.error("kubectl is required (or pass --vm-url, --loki-url and --no-kubectl)")
    report = Report(color=sys.stdout.isatty() and not args.no_color)

    with contextlib.ExitStack() as stack:
        vm_url = args.vm_url or stack.enter_context(
            port_forward("monitoring", "svc/vmsingle-victoria-metrics-k8s-stack", 8428, "/vmsingle"))
        loki_url = args.loki_url or stack.enter_context(port_forward("monitoring", "svc/loki", 3100))
        vm, loki = VM(vm_url), Loki(loki_url)
        now = time.time()

        if not args.skip_sweep:
            sweep(report, vm, loki, range_s, now, args.verbose)
        targeted_checks(report, vm, loki, args, now)

        if args.grafana or args.grafana_url:
            base = args.grafana_url or stack.enter_context(
                port_forward("monitoring", "svc/victoria-metrics-k8s-stack-grafana", 80))
            token, basic = os.environ.get("GRAFANA_TOKEN"), os.environ.get("GRAFANA_BASIC_AUTH")
            if token:
                auth = f"Bearer {token}"
            elif basic:
                auth = "Basic " + base64.b64encode(basic.encode()).decode()
            else:
                secret = kubectl_json("-n", "monitoring", "get", "secret", "grafana-admin")["data"]
                user = base64.b64decode(secret["admin-user"]).decode()
                password = base64.b64decode(secret["admin-password"]).decode()
                auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
            grafana_checks(report, base.rstrip("/"), auth)

        if args.spoof_url:
            spoof_check(report, vm, loki, args.spoof_url, args.spoof_wait)

    section("Summary")
    for status in ("PASS", "WARN", "FAIL", "SKIP"):
        print(f"  {status}: {report.count(status)}")
    sweep_rows = [r for r in report.rows if r[0] == "sweep"]
    print(f"  dashboard queries: {sum(1 for r in sweep_rows if r[1] == 'ERROR')} errors, "
          f"{sum(1 for r in sweep_rows if r[1] == 'EMPTY')} empty (No data right now)")
    failed = report.count("FAIL") + report.count("ERROR")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
