#!/usr/bin/env python3
"""Compare Alloy's loki_process_custom_* metrics with the fixture truth. Exact equality.
usage: validate-alloy-metrics-check.py <truth.json> <metrics url>"""
import collections, json, re, sys, time, urllib.request

truth_path, url = sys.argv[1:3]
truth = json.load(open(truth_path))
PREFIX = "loki_process_custom_taskflow_waf_"
LINE = re.compile(r"^(loki_process_custom_\w+)\{([^}]*)\}\s+([0-9.eE+-]+)$")
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def scrape():
    rows = []
    for line in opener.open(url, timeout=20).read().decode().splitlines():
        match = LINE.match(line)
        if match:
            rows.append((match.group(1), dict(re.findall(r'(\w+)="([^"]*)"', match.group(2))), float(match.group(3))))
    return rows


# Fixtures are tailed from disk: wait until the request total stops moving.
previous, rows = -1.0, []
for _ in range(60):
    try:
        rows = scrape()
    except OSError:
        time.sleep(2)
        continue
    total = sum(v for n, _, v in rows if n == PREFIX + "requests_total")
    if total > 0 and total == previous:
        break
    previous = total
    time.sleep(3)


def aggregate(name, keys):
    counter = collections.Counter()
    for metric, labels, value in rows:
        if metric == PREFIX + name:
            counter[tuple(labels.get(key, "") for key in keys)] += value
    return counter


failures = []


def check(title, got, want_rows):
    want = collections.Counter({tuple(row[:-1]): row[-1] for row in want_rows})
    if got == want:
        print(f"  ok   {title}: {sum(got.values()):.0f} across {len(got)} series")
        return
    failures.append(title)
    print(f"  FAIL {title}: got {sum(got.values()):.0f}, expected {sum(want.values())}")
    for key in sorted(set(got) | set(want)):
        if got.get(key, 0) != want.get(key, 0):
            print(f"       {key}: got {got.get(key, 0):.0f}, expected {want.get(key, 0)}")


check("requests by application, status and normalised method", aggregate("requests_total", ["application", "status", "method"]), truth["requests"])
check("rate-limited by application and zone", aggregate("rate_limited_total", ["application", "zone"]), truth["limited"])
check("audit records by application and interruption", aggregate("audit_records_total", ["application", "interrupted"]), truth["audit"])
check("detection records by application and interruption", aggregate("detection_records_total", ["application", "interrupted"]), truth["detections"])
check("first rule by application and rule ID", aggregate("first_rule_total", ["application", "rule_id"]), truth["rules"])

buckets = collections.defaultdict(dict)
for metric, labels, value in rows:
    if metric.startswith(PREFIX + "request_duration_seconds_"):
        kind = metric.rsplit("_", 1)[1]
        buckets[labels["application"]][labels["le"] if kind == "bucket" else kind] = value
for app, want in truth["histogram"].items():
    got = buckets[app]
    problems = []
    if got.get("count") != want["count"]:
        problems.append(f"count {got.get('count')} != {want['count']}")
    if abs(got.get("sum", 0) - want["sum"]) > 1e-3:
        problems.append(f"sum {got.get('sum')} != {want['sum']}")
    for bound, expected in zip(truth["buckets"], want["buckets"]):
        actual = next((got[k] for k in (repr(float(bound)), str(bound), "%g" % bound) if k in got), None)
        if actual != expected:
            problems.append(f"le={bound}: {actual} != {expected}")
    if problems:
        failures.append(f"duration histogram {app}")
        print(f"  FAIL duration histogram {app}: " + "; ".join(problems))
    else:
        print(f"  ok   duration histogram {app}: {want['count']} requests, sum {want['sum']:.3f}s")

allowed = {"application", "component_id", "component_path", "status", "method", "zone", "interrupted", "rule_id", "le"}
unexpected = sorted({key for _, labels, _ in rows for key in labels} - allowed)
if unexpected:
    failures.append("label hygiene")
    print(f"  FAIL unintended metric labels (pod, filename, client data ...): {unexpected}")
else:
    print("  ok   only application, status, method, zone, interrupted and rule_id are metric labels")

sys.exit(1 if failures else 0)
