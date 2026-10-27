#!/usr/bin/env python3
"""Exercise shipped WAF dashboard MetricsQL against an isolated TSDB.

No cluster access or external TSDB URL is accepted: fixture imports and flushes
only target the disposable process/container created here. Requires Python 3 and
Docker, or VM_BINARY pointing to a local VictoriaMetrics executable.
VM_IMAGE defaults to the VMSingle image bundled with stack chart 0.97.0; use the
same version when supplying VM_BINARY.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parents[4]
PREFIX = "loki_process_custom_taskflow_waf_"


def panels(items):
    for panel in items:
        yield panel
        yield from panels(panel.get("panels", []))


class WafDashboardMetricsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dashboards = {}
        for name in ("taskflow-rate-limits", "taskflow-waf"):
            path = ROOT / f"gitops/monitoring/logging/dashboards/{name}.json"
            cls.dashboards[name] = {p["id"]: p for p in panels(json.loads(path.read_text())["panels"])}
        # Other dashboards whose counter queries are checked against the same gap fixtures.
        cls.extra = {}
        for name in ("falco-official", "logging-pipeline"):
            path = ROOT / f"gitops/monitoring/logging/dashboards/{name}.json"
            cls.extra[name] = {p["id"]: p for p in panels(json.loads(path.read_text())["panels"])}
        image = os.environ.get("VM_IMAGE", "victoriametrics/victoria-metrics:v1.155.0")
        flags = ["-memory.allowedBytes=96MiB", "-storage.minFreeDiskSpaceBytes=10MB"]
        binary = os.environ.get("VM_BINARY")
        if binary:
            directory = tempfile.TemporaryDirectory(prefix="waf-dashboard-metrics-")
            cls.addClassCleanup(directory.cleanup)
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            log = tempfile.TemporaryFile()
            cls.process_log = log
            cls.addClassCleanup(log.close)
            cls.process = subprocess.Popen([
                binary, *flags, f"-httpListenAddr=127.0.0.1:{port}",
                f"-storageDataPath={directory.name}",
            ], stdout=log, stderr=log)
            cls.addClassCleanup(cls.cleanup_process)
            runtime = f"{binary} (disposable local process)"
        else:
            cls.container = subprocess.check_output([
                "docker", "run", "--rm", "-d", "--publish", "127.0.0.1::8428",
                "--memory=256m", image, *flags,
            ], text=True).strip()
            cls.addClassCleanup(cls.cleanup_container)
            port = subprocess.check_output([
                "docker", "inspect", "--format",
                '{{(index (index .NetworkSettings.Ports "8428/tcp") 0).HostPort}}',
                cls.container,
            ], text=True).strip()
            runtime = f"{image} (disposable container)"
        cls.url = f"http://127.0.0.1:{port}"
        for attempt in range(60):
            try:
                cls.request("/health")
                break
            except (OSError, urllib.error.URLError):
                if attempt == 59:
                    raise
                time.sleep(0.5)
        # Keep all fixture times in the past, on the same 30-second scrape grid.
        cls.end = (int(time.time()) // 30) * 30 - 60
        cls.seed()
        print(f"Dashboard MetricsQL fixtures: {runtime}", flush=True)

    @classmethod
    def cleanup_process(cls):
        cls.process.terminate()
        try:
            cls.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            cls.process.kill()
            cls.process.wait()
        if cls._classSetupFailed:
            cls.process_log.seek(0)
            print(cls.process_log.read().decode(), flush=True)

    @classmethod
    def cleanup_container(cls):
        if cls._classSetupFailed:
            subprocess.run(["docker", "logs", cls.container], check=False)
        subprocess.run(["docker", "rm", "-f", cls.container],
                       stdout=subprocess.DEVNULL, check=False)

    @classmethod
    def request(cls, path, params=None, data=None):
        if params:
            path += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(cls.url + path, data=data)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            raise AssertionError(f"{path}: HTTP {error.code}: {error.read().decode()}") from error

    @classmethod
    def seed(cls):
        rows = []

        def series(name, application, labels, start, value):
            offsets = list(range(start, 1, 30))
            rows.append({
                "metric": {"__name__": PREFIX + name, "application": application, **labels},
                "values": [value(t) if callable(value) else value for t in offsets],
                "timestamps": [(cls.end + t) * 1000 for t in offsets],
            })

        def requests(app, status, value, start=-600):
            series("requests_total", app, {"method": "GET", "status": str(status)}, start, value)

        # Reproduce the real first-scrape burst: 17 frontend + 7 backend requests.
        requests("first-frontend", 200, 17)
        requests("first-backend", 200, 5)
        requests("first-backend", 401, 2)
        requests("upstream", 200, 100)
        requests("upstream", 429, 3)  # No Caddy rejection metric exists for this app.
        requests("mixed", 200, 100)
        requests("mixed", 429, 7)
        series("rate_limited_total", "mixed", {"zone": "api"}, -600, 4)
        series("rate_limited_total", "mixed", {"zone": ""}, -600, 99)
        for interrupted, count in [("true", 2), ("false", 1)]:
            series("detection_records_total", "mixed", {"interrupted": interrupted}, -600, count)
            series("audit_records_total", "mixed", {"interrupted": interrupted}, -600, count)
        requests("quiet", 200, 24, start=-1800)
        requests("reset", 200, lambda t: 10 if t < -900 else (2 if t < -600 else 5), start=-1800)
        # Real missing counter samples across the left edge of a 5-minute window,
        # not just up=0 with a continuously sampled counter. All scrapes recover
        # before the evaluation time; the previous sample is within the bounded
        # one-hour history guard used by the dashboards.
        for app, last_before_gap in [("gap-short", -420), ("gap-long", -900)]:
            offsets = list(range(-7200, last_before_gap + 1, 30)) + list(range(-240, 1, 30))
            for name, labels in [
                ("requests_total", {"method": "GET", "status": "429"}),
                ("rate_limited_total", {"zone": "api"}),
                ("detection_records_total", {"interrupted": "true"}),
                ("audit_records_total", {"interrupted": "true"}),
            ]:
                rows.append({
                    "metric": {"__name__": PREFIX + name, "application": app, **labels},
                    "values": [5000 if t < -240 else (5001 if t < -120 else 5003) for t in offsets],
                    "timestamps": [(cls.end + t) * 1000 for t in offsets],
                })
        # A pod first observed at zero, then restarting inside its first interval.
        # Replacing kube-state-metrics must not replay an old pod's restart total.
        for pod, exporter, offsets, values in [
            ("taskflow-backend-waf-new", "ksm-old", [-240, -210, -180, -150], [0, 0, 1, 1]),
            ("taskflow-backend-waf-new", "ksm-new", list(range(-120, 1, 30)), [1] * 5),
            ("taskflow-frontend-waf-old", "ksm-old", list(range(-900, -149, 30)), [7] * 26),
            ("taskflow-frontend-waf-old", "ksm-new", list(range(-120, 1, 30)), [7] * 5),
        ]:
            rows.append({
                "metric": {"__name__": "kube_pod_container_status_restarts_total",
                           "namespace": "taskflow", "pod": pod, "container": "waf", "instance": exporter},
                "values": values,
                "timestamps": [(cls.end + t) * 1000 for t in offsets],
            })
        # Falco rule matches and Loki discards: the same missing-sample shape, plus
        # a series born inside the window whose first burst must still count.
        gap = list(range(-7200, -899, 30)) + list(range(-240, 1, 30))
        gap_values = [5000 if t < -240 else (5001 if t < -120 else 5003) for t in gap]
        born = list(range(-240, 1, 30))
        steady = list(range(-7200, 1, 30))
        for name, labels, offsets, values in [
            ("falcosecurity_falco_rules_matches_total",
             {"namespace": "falco", "pod": "falco-a", "rule_name": "gap", "source": "syscall", "priority": "5"},
             gap, gap_values),
            ("falcosecurity_falco_rules_matches_total",
             {"namespace": "falco", "pod": "falco-a", "rule_name": "born", "source": "syscall", "priority": "4"},
             born, [7] * len(born)),
            ("loki_discarded_samples_total", {"reason": "line_too_long", "tenant": "gap"}, gap, gap_values),
            ("loki_discarded_samples_total", {"reason": "too_far_behind", "tenant": "born"}, born, [7] * len(born)),
            ("loki_distributor_bytes_received_total", {"tenant": "fake"}, steady,
             [1000 * i for i in range(len(steady))]),
        ]:
            rows.append({
                "metric": {"__name__": name, **labels},
                "values": values,
                "timestamps": [(cls.end + t) * 1000 for t in offsets],
            })
        offsets = list(range(-3600, 1, 30))
        rows.append({
            "metric": {"__name__": "up", "job": "alloy"},
            "values": [0 if t in (-60, -30) else 1 for t in offsets],
            "timestamps": [(cls.end + t) * 1000 for t in offsets],
        })
        cls.request("/api/v1/import", data="\n".join(json.dumps(r) for r in rows).encode())
        cls.request("/internal/force_flush")

    def query(self, dashboard, panel, application, ref="A", window="1h", when=None, interval="15m", range_step=None):
        items = self.dashboards.get(dashboard) or self.extra[dashboard]
        target = next(t for t in items[panel]["targets"] if t["refId"] == ref)
        expr = target["expr"]
        substitutions = {
            "$__rate_interval_ms": "300000", "$__rate_interval": "5m",
            "$__range": window, "$__interval": interval, "$application": application,
            "$namespace": ".*", "$source": ".*", "$priority": ".*", "$pod": ".*",
        }
        for variable, value in substitutions.items():
            expr = expr.replace(variable, value)
        self.assertNotRegex(expr, r"\$\w+", expr)
        end = self.end if when is None else when
        params = {"query": expr, "time": end, "nocache": "1"}
        endpoint = "/api/v1/query"
        if range_step:
            endpoint = "/api/v1/query_range"
            params.update(start=end - 300, end=end, step=range_step)
        result = json.loads(self.request(endpoint, params))
        self.assertEqual("success", result["status"], expr)
        if range_step:
            return {tuple(sorted((k, v) for k, v in row["metric"].items() if k != "__name__")): float(row["values"][-1][1])
                    for row in result["data"]["result"] if row["values"][-1][0] == end}
        return {tuple(sorted((k, v) for k, v in row["metric"].items() if k != "__name__")): float(row["value"][1])
                for row in result["data"]["result"]}

    def rate(self, panel, application, **kwargs):
        return self.query("taskflow-rate-limits", panel, application, **kwargs)

    def waf(self, panel, application, **kwargs):
        return self.query("taskflow-waf", panel, application, **kwargs)

    def test_first_burst_included_with_application_filter(self):
        self.assertEqual({(): 24}, self.rate(201, "first-.*"))
        self.assertEqual({(): 17}, self.rate(201, "first-frontend"))
        self.assertEqual({(): 7}, self.rate(201, "first-backend"))
        self.assertEqual({(): 24}, self.rate(201, "first-.*", when=self.end - 570, window="5m"))

    def test_reset_and_window_boundaries(self):
        self.assertEqual({(): 15}, self.rate(201, "reset"), "10 initial + 2 after reset + 3 later")
        # The sample exactly at the left boundary is the baseline. Including
        # the preceding scrape brings the 2 -> 5 increment into the window.
        self.assertEqual({(): 3}, self.rate(201, "reset", window="601s"))
        self.assertEqual({(): 0}, self.rate(201, "reset", window="10m"))
        self.assertEqual({(): 0}, self.rate(201, "reset", window="5m"))
        self.assertEqual({(): 0}, self.rate(201, "quiet", window="5m"), "not the cumulative 24")

    def test_upstream_429_without_caddy_counter(self):
        self.assertEqual({(): 3}, self.rate(102, "upstream"))
        self.assertEqual({(): 0}, self.rate(103, "upstream"))
        self.assertEqual({(): 0}, self.rate(5, "upstream", ref="B"))
        self.assertEqual({(): 3}, self.rate(5, "upstream", ref="C"))

    def test_missing_samples_do_not_recount_lifetime_totals(self):
        # Short gaps retain the preceding sample (3 events). Beyond the engine's
        # lookback the hybrid uses increase(): only 2 events after the first
        # recovered sample are observable, not the cumulative value of 5003.
        for app, expected in [("gap-short", 3), ("gap-long", 2)]:
            for dashboard, panel, ref in [
                ("taskflow-rate-limits", 201, "A"),
                ("taskflow-rate-limits", 102, "A"),
                ("taskflow-rate-limits", 103, "A"),
                ("taskflow-rate-limits", 5, "A"),
                ("taskflow-rate-limits", 5, "B"),
                ("taskflow-waf", 201, "A"),
                ("taskflow-waf", 202, "A"),
            ]:
                with self.subTest(app=app, dashboard=dashboard, panel=panel, ref=ref):
                    self.assertEqual({(): expected}, self.query(
                        dashboard, panel, app, ref=ref, window="5m", interval="5m"))
            self.assertEqual({(("application", app),): expected / 300}, self.rate(6, app))
            self.assertEqual({(): 100}, self.rate(104, app, window="5m"))
            self.assertEqual({(): 100}, self.waf(204, app, window="5m"))
            for ref in ("A", "B"):
                self.assertEqual({(("application", app),): expected},
                                 self.waf(205, app, ref=ref, interval="5m"))
                # A range evaluation loads earlier samples too, retaining the
                # pre-gap baseline here even when the instant query cannot.
                self.assertEqual({(("application", app),): 3},
                                 self.waf(205, app, ref=ref, interval="5m", range_step=30))

    def test_restarts_in_first_interval_and_ksm_replacement(self):
        self.assertEqual({
            (("pod", "taskflow-backend-waf-new"),): 1,
            (("pod", "taskflow-frontend-waf-old"),): 0,
        }, self.waf(12, ".*", interval="5m"))
        self.assertEqual({
            (("pod", "taskflow-backend-waf-new"),): 1,
            (("pod", "taskflow-frontend-waf-old"),): 0,
        }, self.waf(12, ".*", interval="5m", range_step=30))

    def test_falco_and_loki_range_counters_survive_gaps_and_keep_first_bursts(self):
        # Instant queries over the selected range: a gap at the window start must
        # not replay the 5000 lifetime total; a series born inside keeps its 7.
        expected = {
            1: {(("rule_name", "gap"),): 2, (("rule_name", "born"),): 7},
            2: {(("source", "syscall"),): 9},
            3: {(("priority", "5"),): 2, (("priority", "4"),): 7},
        }
        for panel, values in expected.items():
            with self.subTest(dashboard="falco-official", panel=panel):
                self.assertEqual(values, self.query("falco-official", panel, ".*", window="5m"))
        with self.subTest(dashboard="logging-pipeline", panel=3):
            self.assertEqual({(): 9}, self.query("logging-pipeline", 3, ".*", window="5m"))
        # Charts are range queries: the engine loads the pre-gap baseline, so the
        # plain increase_pure() bars count 3, not the lifetime total.
        with self.subTest(dashboard="falco-official", panel=19):
            self.assertEqual({(("rule_name", "gap"),): 3, (("rule_name", "born"),): 7},
                             self.query("falco-official", 19, ".*", interval="5m", range_step=30))
        with self.subTest(dashboard="logging-pipeline", panel=7):
            self.assertEqual({(("reason", "line_too_long"),): 3, (("reason", "too_far_behind"),): 7},
                             self.query("logging-pipeline", 7, ".*", interval="5m", range_step=30))

    def test_mixed_429s_and_nonempty_zones(self):
        self.assertEqual({(): 7}, self.rate(102, "mixed"))
        self.assertEqual({(): 4}, self.rate(103, "mixed"), "ignore empty-zone series")
        self.assertEqual({(): 4}, self.rate(5, "mixed", ref="B"))
        self.assertEqual({(): 3}, self.rate(5, "mixed", ref="C"))
        self.assertAlmostEqual(100 * 4 / 107, self.rate(104, "mixed")[()])

    def test_no_rejections_is_zero_only_for_observed_apps(self):
        for panel, ref in [(102, "A"), (103, "A"), (5, "A"), (5, "B"), (5, "C")]:
            with self.subTest(panel=panel, ref=ref):
                self.assertEqual({(): 0}, self.rate(panel, "quiet", ref=ref))
                self.assertEqual({}, self.rate(panel, "missing", ref=ref))
        self.assertEqual({(("application", "quiet"),): 0}, self.rate(4, "quiet"))
        self.assertEqual({}, self.rate(4, "missing"))
        self.assertEqual({}, self.rate(104, "quiet", window="5m"), "no requests is not 0%")

    def test_waf_first_detections_and_zero_baselines(self):
        for panel, expected in [(201, 3), (202, 2), (203, 1)]:
            self.assertEqual({(): expected}, self.waf(panel, "mixed"))
            self.assertEqual({(): 0}, self.waf(panel, "quiet"))
            self.assertEqual({}, self.waf(panel, "missing"))
        self.assertAlmostEqual(100 * 2 / 3, self.waf(204, "mixed")[()])
        self.assertEqual({}, self.waf(204, "quiet"))
        for ref in ("A", "B"):
            self.assertEqual({(("application", "mixed"),): 3}, self.waf(205, "mixed", ref=ref))
            self.assertEqual({(("application", "quiet"),): 0}, self.waf(205, "quiet", ref=ref))
            self.assertEqual({}, self.waf(205, "missing", ref=ref))

    def test_rate_includes_first_burst_and_stays_zero_when_quiet(self):
        values = self.rate(6, "first-.*", when=self.end - 570)
        self.assertAlmostEqual(24 / 300, sum(values.values()))
        self.assertEqual({(("application", "quiet"),): 0}, self.rate(6, "quiet"))

    def test_all_metric_queries_parse_and_hide_scrape_failures(self):
        count = 0
        for dashboard, items in self.dashboards.items():
            for panel in items.values():
                for target in panel.get("targets", []):
                    expr = target.get("expr", "")
                    if PREFIX not in expr:
                        continue
                    count += 1
                    with self.subTest(dashboard=dashboard, panel=panel["id"], ref=target["refId"]):
                        self.assertNotRegex(expr, r"\brate\(loki_process_custom_taskflow_waf_")
                        self.assertIn("unless last_over_time(", expr)
                        self.assertIn("or increase(", expr)
                        self.assertNotIn("vector(0)", expr)
                        self.query(dashboard, panel["id"], ".*", ref=target["refId"])
                        self.assertEqual({}, self.query(dashboard, panel["id"], ".*", ref=target["refId"], when=self.end - 30))
        self.assertEqual(19, count, "exercise all custom WAF metric targets")
        self.assertEqual({(): 24}, self.rate(201, "first-.*"), "recovery must not invent a new burst")


if __name__ == "__main__":
    unittest.main(verbosity=2)
