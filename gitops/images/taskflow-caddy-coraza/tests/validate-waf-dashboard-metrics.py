#!/usr/bin/env python3
"""Exercise shipped WAF dashboard MetricsQL against an isolated Docker TSDB.

No cluster access or external TSDB URL is accepted: fixture imports and flushes
only target the disposable container created here. Requires Docker and Python 3.
VM_IMAGE defaults to the VMSingle image bundled with stack chart 0.96.0.
"""
import json
import os
from pathlib import Path
import subprocess
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
        image = os.environ.get("VM_IMAGE", "victoriametrics/victoria-metrics:v1.154.0")
        cls.container = subprocess.check_output([
            "docker", "run", "--rm", "-d", "--publish", "127.0.0.1::8428",
            "--memory=256m", image, "-memory.allowedBytes=96MiB",
            "-storage.minFreeDiskSpaceBytes=10MB",
        ], text=True).strip()
        cls.addClassCleanup(cls.cleanup_container)
        port = subprocess.check_output([
            "docker", "inspect", "--format",
            '{{(index (index .NetworkSettings.Ports "8428/tcp") 0).HostPort}}',
            cls.container,
        ], text=True).strip()
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
        print(f"Dashboard MetricsQL fixtures: {image} (disposable container)", flush=True)

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
        offsets = list(range(-3600, 1, 30))
        rows.append({
            "metric": {"__name__": "up", "job": "alloy"},
            "values": [0 if t in (-60, -30) else 1 for t in offsets],
            "timestamps": [(cls.end + t) * 1000 for t in offsets],
        })
        cls.request("/api/v1/import", data="\n".join(json.dumps(r) for r in rows).encode())
        cls.request("/internal/force_flush")

    def query(self, dashboard, panel, application, ref="A", window="1h", when=None, interval="15m"):
        target = next(t for t in self.dashboards[dashboard][panel]["targets"] if t["refId"] == ref)
        expr = target["expr"]
        substitutions = {
            "$__rate_interval_ms": "300000", "$__rate_interval": "5m",
            "$__range": window, "$__interval": interval, "$application": application,
        }
        for variable, value in substitutions.items():
            expr = expr.replace(variable, value)
        self.assertNotRegex(expr, r"\$\w+", expr)
        result = json.loads(self.request("/api/v1/query", {
            "query": expr, "time": self.end if when is None else when, "nocache": "1",
        }))
        self.assertEqual("success", result["status"], expr)
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
                        self.assertNotRegex(expr, r"\b(?:increase|last_over_time|rate)\(loki_process_custom_taskflow_waf_")
                        self.assertNotIn("vector(0)", expr)
                        self.query(dashboard, panel["id"], ".*", ref=target["refId"])
                        self.assertEqual({}, self.query(dashboard, panel["id"], ".*", ref=target["refId"], when=self.end - 30))
        self.assertEqual(19, count, "exercise all custom WAF metric targets")
        self.assertEqual({(): 24}, self.rate(201, "first-.*"), "recovery must not invent a new burst")


if __name__ == "__main__":
    unittest.main(verbosity=2)
