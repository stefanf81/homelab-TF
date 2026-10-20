#!/usr/bin/env python3
"""Write fixture WAF logs (Caddy access records, kubelet probes, Coraza audit records) with exactly
known counts, and the expected metric values, for validate-alloy-metrics.sh.
usage: validate-alloy-metrics-fixtures.py <logs dir> <truth.json>"""
import collections, copy, json, random, sys

out_dir, truth_path = sys.argv[1:3]
random.seed(11)
BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
APPS = {"taskflow-frontend": "frontend.log", "taskflow-backend": "backend.log"}
ZONES = {"taskflow-frontend": ["general"], "taskflow-backend": ["api", "authentication"]}
RULE_IDS = ["930130", "942100", "913100", "920350", "949110"]
# The method is client controlled: everything outside the usual set must collapse to OTHER.
METHODS = ["GET"] * 60 + ["POST"] * 20 + ["PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"] * 2 + ["PROPFIND", "XYZZY", "get", "CONNECT"]
USUAL = ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS")

requests, limited, audit, detections, rules = (collections.Counter() for _ in range(5))
hist = {app: {"count": 0, "sum": 0.0, "buckets": [0] * len(BUCKETS)} for app in APPS}
security = {}
spoofs = {}  # spoof fixture id -> the rule_id label Loki must carry ("" = none)
# Client-controlled header KEYS and values that mimic the audit needles. Coraza lowercases
# request header names into transaction.request.headers (before the top-level messages
# array), so "Messages: ..." becomes "messages":["..."] there. Only the top-level
# `},"messages":[{` array may count as a detection or supply a rule ID.
SPOOF_HEADERS = {
    "messages": ['[id "999001"] [msg "Injected rule"] [tag "paranoia-level/4"]'],
    "user-agent": ['x combined=999999999999 [id "999002"] [msg "spoofed"] [tag "paranoia-level/4"]'],
    "stopwatch": ["1 2; combined=999999999999"],
}

for app, filename in APPS.items():
    lines = []
    for i in range(6000):
        method = random.choice(METHODS)
        status = random.choices([200, 304, 401, 403, 404, 429, 500, 502], [70, 6, 3, 3, 8, 6, 2, 2])[0]
        zone = random.choice(ZONES[app]) if status == 429 and random.random() < 0.8 else ""
        duration = round(random.lognormvariate(-4.0, 1.2), 6)
        record = {
            "level": "info", "ts": 1.0 + i, "logger": "http.log.access.log0", "msg": "handled request",
            "request": {"client_ip": "203.0.113.%d" % random.randint(1, 250), "method": method,
                        "host": "www.jokelab.dev", "uri": random.choice(["/", "/api/v1/appointments?page=1", "/assets/a.js", "/.env", "/login"])},
            "duration": duration, "size": 10, "status": status, "client_ip": "203.0.113.9",
            # Caddy logs an unset log_append placeholder as null. Empty and missing
            # values are mixed in so none of the three shapes counts as a rejection.
            "rate_limit_zone": zone or random.choices([None, "", "missing"], [90, 5, 5])[0],
        }
        if record["rate_limit_zone"] == "missing":
            del record["rate_limit_zone"]
        lines.append(json.dumps(record, separators=(",", ":")))
        requests[(app, str(status), method if method in USUAL else "OTHER")] += 1
        if zone:
            limited[(app, zone)] += 1
        h = hist[app]
        h["count"] += 1
        h["sum"] += duration
        for j, bound in enumerate(BUCKETS):
            if duration <= bound:
                h["buckets"][j] += 1
    for _ in range(300):  # kubelet probes must not be counted
        lines.append(json.dumps({"level": "info", "msg": "handled request", "request": {"method": "GET", "uri": "/waf-healthz", "host": "10.0.0.1:8080"},
                                 "duration": 0.0001, "status": 200}, separators=(",", ":")))
    lines.append(json.dumps({"level": "info", "msg": "something else", "status": 200}))  # not an access record
    # Client-controlled text that mimics the selectors' needles. Values are JSON
    # strings, so their quotes are escaped and must never satisfy a key match.
    for spoof in ["transaction", "messages", '"transaction":{', '"messages":['] * 10:
        duration = 0.002
        lines.append(json.dumps({
            "level": "info", "msg": "handled request", "status": 200, "duration": duration, "rate_limit_zone": None,
            "request": {"method": "GET", "uri": "/", "headers": {"User-Agent": [spoof]}},
        }, separators=(",", ":")))
        requests[(app, "200", "GET")] += 1
        h = hist[app]
        h["count"] += 1
        h["sum"] += duration
        for j, bound in enumerate(BUCKETS):
            if duration <= bound:
                h["buckets"][j] += 1
    for spoof in ["handled request", '"msg":"handled request"'] * 10:
        lines.append(json.dumps({"transaction": {"client_ip": "198.51.100.7", "is_interrupted": False,
                                                 "request": {"method": "GET", "uri": "/", "headers": {"x-test": [spoof]}}}},
                                separators=(",", ":")))
        audit[(app, "false")] += 1
    for _ in range(1500):
        interrupted = random.random() < 0.5
        has_messages = random.random() < 0.8
        rule = random.choice(RULE_IDS)
        record = {"transaction": {"client_ip": "198.51.100.%d" % random.randint(1, 250), "is_interrupted": interrupted,
                                  "request": {"method": "GET", "uri": "/x"}}}
        if has_messages:
            record["messages"] = [{"error_message": f'[client "x"] Coraza: Warning. Thing [file "f"] [id "{rule}"] [msg "Thing"] [tag "paranoia-level/1"]'}]
        lines.append(json.dumps(record, separators=(",", ":")))
        flag = "true" if interrupted else "false"
        audit[(app, flag)] += 1
        if has_messages:
            detections[(app, flag)] += 1
            rules[(app, rule)] += 1
    # Spoofed audit records in the real Coraza shape (headers before messages, Go %q
    # quoting inside error_message, so client data in [data "..."] is escaped twice).
    # Even ids are genuine detections and must count once with their real rule; odd ids
    # have no rule matches (an audited 404) and must count only as audit records.
    for i in range(20):
        fixture_id = f"{app}-spoof-{i}"
        record = {"spoof_fixture_id": fixture_id,
                  "transaction": {"client_ip": "192.0.2.9", "is_interrupted": False,
                                  "request": {"method": "GET", "uri": "/nonexistent", "headers": SPOOF_HEADERS},
                                  "producer": {"stopwatch": "1 2; combined=1500000, p1=1, p2=2, p3=0, p4=0, p5=0"}}}
        audit[(app, "false")] += 1
        spoofs[fixture_id] = ""
        if i % 2 == 0:
            rule = random.choice(RULE_IDS)
            record["messages"] = [{"actionset": "", "message": "", "data": None, "error_message":
                                   f'[client "192.0.2.9"] Coraza: Warning. Thing [file "f"] [line "1"] [id "{rule}"] [rev ""] [msg "Thing"] '
                                   '[data "Matched Data: [id \\"999003\\"] [tag \\"paranoia-level/4\\"] found"] [tag "paranoia-level/1"]'}]
            detections[(app, "false")] += 1
            rules[(app, rule)] += 1
            spoofs[fixture_id] = rule
        lines.append(json.dumps(record, separators=(",", ":")))
    # Exercise the actual Loki redactor, not just the metrics-only fan-out.
    # Every secret below is synthetic. Headers include multiple values, empty
    # arrays, literal ']', escaped quotes/backslashes and mixed-case keys.
    for i, method in enumerate([*USUAL, "PROPFIND", "REVIEW_METHOD_ONE", "REVIEW_METHOD_TWO", "get"]):
        fixture_id = f"{app}-{i}"
        token = f"SYNTHETIC_SECRET_{i}"
        record = {
            "redaction_fixture_id": fixture_id,
            "transaction": {
                "client_ip": "192.0.2.1", "is_interrupted": False,
                "request": {
                    "method": method,
                    "uri": f'/?public=keep&access_token={token}&code={token}&password={token}\\"quoted&after=keep',
                    "headers": {
                        "Authorization": [f'Bearer {token}]\\"quoted', f"second {token}"],
                        "pRoXy-AuThOrIzAtIoN": [token],
                        "cookie": [f"sid={token}; quoted=\"x]\""],
                        "COOKIE": [],
                        "X-Keep": ["non-secret evidence"],
                    },
                },
                "response": {"headers": {"Set-Cookie": [f"sid={token}; Secure; HttpOnly"], "X-Keep": ["response evidence"]}},
            },
        }
        expected = copy.deepcopy(record)
        expected["transaction"]["request"]["uri"] = "/?public=keep&access_token=REDACTED&code=REDACTED&password=REDACTED&after=keep"
        for headers in [expected["transaction"]["request"]["headers"], expected["transaction"]["response"]["headers"]]:
            for key in headers:
                if key.lower() in ("authorization", "proxy-authorization", "cookie", "set-cookie"):
                    headers[key] = ["REDACTED"]
        lines.append(json.dumps(record, separators=(",", ":")))
        audit[(app, "false")] += 1
        security[fixture_id] = {"record": expected, "method": method if method in USUAL else "OTHER"}
    # Fail closed: invalid audit JSON must not be stored or counted as an audit.
    lines.append('{"transaction":{"request":{"headers":{"authorization":["SYNTHETIC_TRUNCATED_SECRET"]},"uri":"/"}},"redaction_fixture_id":"malformed-' + app + '"')
    random.shuffle(lines)
    with open(f"{out_dir}/{filename}", "w") as handle:
        handle.write("\n".join(lines) + "\n")

as_rows = lambda counter: [[*key, value] for key, value in counter.items()]
with open(truth_path, "w") as handle:
    json.dump({"requests": as_rows(requests), "limited": as_rows(limited), "audit": as_rows(audit),
               "detections": as_rows(detections), "rules": as_rows(rules), "histogram": hist, "buckets": BUCKETS,
               "security": security, "spoofs": spoofs, "rule_ids": RULE_IDS}, handle)
print(f"fixtures: {sum(requests.values())} requests, {sum(limited.values())} rate-limited, {sum(audit.values())} audit, {sum(detections.values())} detections")
