#!/usr/bin/env python3
"""Check redaction, the oversize-record shrink and bounded labels after the real Alloy -> Loki path.

Usage: validate-alloy-logs-check.py truth.json disposable-loki-url
All credentials in these fixtures are synthetic; never query production secrets.
"""
import json
import sys
import time
import urllib.parse
import urllib.request

truth_all = json.load(open(sys.argv[1]))
truth = truth_all["security"]
url = sys.argv[2].rstrip("/")
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
deadline = time.monotonic() + 60
seen = {}
while True:
    query = urllib.parse.urlencode({
        "query": '{job="coraza-waf",container="waf"} |= "redaction_fixture_id"',
        "start": str(int(time.time()) - 3600), "end": str(int(time.time()) + 1), "limit": 1000,
    })
    with opener.open(url + "/loki/api/v1/query_range?" + query, timeout=15) as response:
        result = json.load(response)
    assert result["status"] == "success", result
    for stream in result["data"]["result"]:
        for _, line in stream["values"]:
            assert "SYNTHETIC_" not in line, "synthetic secret survived redaction"
            record = json.loads(line)  # Invalid JSON must never reach Loki.
            key = record["redaction_fixture_id"]
            assert key in truth, f"unexpected/malformed fixture reached Loki: {key}"
            assert record == truth[key]["record"], f"redaction damaged evidence or missed a value: {key}"
            assert stream["stream"].get("method", "") == truth[key]["method"], f"unbounded/wrong method label: {key}"
            assert stream["stream"].get("rule_id", "") == truth[key].get("rule_id", ""), f"wrong rule_id label: {key}"
            seen[key] = record
    if len(seen) == len(truth):
        break
    if time.monotonic() >= deadline:
        raise AssertionError(f"missing fixture records: {sorted(set(truth) - set(seen))}")
    time.sleep(1)
print(f"  ok   {len(seen)} audit, rule-line and access fixtures: secrets removed (also matched data, other query keys, \\u0026), duplicate URIs dropped, oversize record stored, evidence preserved, bounded methods")

# Header-key spoofs: only the top-level messages array may supply a rule_id label.
spoofs = truth_all["spoofs"]
deadline = time.monotonic() + 60
seen = {}
while True:
    query = urllib.parse.urlencode({
        "query": '{job="coraza-waf",container="waf"} |= "spoof_fixture_id"',
        "start": str(int(time.time()) - 3600), "end": str(int(time.time()) + 1), "limit": 1000,
    })
    with opener.open(url + "/loki/api/v1/query_range?" + query, timeout=15) as response:
        result = json.load(response)
    assert result["status"] == "success", result
    for stream in result["data"]["result"]:
        for _, line in stream["values"]:
            key = json.loads(line)["spoof_fixture_id"]
            got = stream["stream"].get("rule_id", "")
            assert got == spoofs[key], f"spoofed rule_id label {got!r} on {key}, expected {spoofs[key]!r}"
            seen[key] = got
    if len(seen) == len(spoofs):
        break
    if time.monotonic() >= deadline:
        raise AssertionError(f"missing spoof fixture records: {sorted(set(spoofs) - set(seen))}")
    time.sleep(1)
query = urllib.parse.urlencode({"query": '{job="coraza-waf",container="waf"}',
                                "start": str(int(time.time()) - 3600), "end": str(int(time.time()) + 1)})
with opener.open(url + "/loki/api/v1/label/rule_id/values?" + query, timeout=15) as response:
    labels = set(json.load(response).get("data") or [])
assert labels <= set(truth_all["rule_ids"]), f"rule_id labels outside the fixture rules: {sorted(labels - set(truth_all['rule_ids']))}"
print(f"  ok   {len(seen)} header-key spoof fixtures: no injected rule_id labels, genuine rules kept")

# Prove exact message and stream scope against the real platform pipeline. Compare
# whole bodies so normalizing an extracted copy cannot silently strip ANSI from
# retained warnings/errors. Waiting for all retained records also drains each file.
platform = {fixture["name"]: fixture for fixture in truth_all["platform"]}
deadline = time.monotonic() + 60
while True:
    query = urllib.parse.urlencode({
        "query": '{job="cluster-platform",fixture_stream=~".+"}',
        "start": str(int(time.time()) - 3600), "end": str(int(time.time()) + 1), "limit": 1000,
    })
    with opener.open(url + "/loki/api/v1/query_range?" + query, timeout=15) as response:
        result = json.load(response)
    assert result["status"] == "success", result
    seen = {name: set() for name in platform}
    for stream in result["data"]["result"]:
        name = stream["stream"]["fixture_stream"]
        expected = set(platform[name]["kept"])
        for _, line in stream["values"]:
            assert line in expected, f"unexpected/modified platform record reached Loki: {name}: {line!r}"
            seen[name].add(line)
    missing = {name: len(set(fixture["kept"]) - seen[name]) for name, fixture in platform.items()}
    if not any(missing.values()):
        break
    if time.monotonic() >= deadline:
        raise AssertionError(f"missing retained platform records: {missing}")
    time.sleep(1)
print(f"  ok   {len(platform)} platform streams: exact Kyverno deprecations dropped; other warnings, errors, callers, namespaces, containers and original ANSI bodies retained")

# Backend console logs, plain pattern and ECS JSON (prod default): every record must arrive as
# exactly one Loki entry. JSON lines must never be glued onto the previous record (one object per
# entry, parseable), plain stack traces must be reassembled, and Loki must derive the level from
# ECS's nested log.level, so Grafana's level filter keeps working after the switch.
backend = {fixture["name"]: fixture for fixture in truth_all["backend"]}
deadline = time.monotonic() + 60
while True:
    query = urllib.parse.urlencode({
        "query": '{job="taskflow-app",application="taskflow-backend",fixture_stream=~"backend-.+"}',
        "start": str(int(time.time()) - 3600), "end": str(int(time.time()) + 1), "limit": 5000,
    })
    with opener.open(url + "/loki/api/v1/query_range?" + query, timeout=15) as response:
        result = json.load(response)
    assert result["status"] == "success", result
    got = {name: [] for name in backend}
    for stream in result["data"]["result"]:
        assert stream["stream"].get("source") == "app", f"backend pipeline label missing: {stream['stream']}"
        got[stream["stream"]["fixture_stream"]] += [line for _, line in stream["values"]]
    if all(len(got[name]) >= len(fixture["records"]) for name, fixture in backend.items()):
        break
    if time.monotonic() >= deadline:
        raise AssertionError(f"missing backend records: { {n: (len(got[n]), len(f['records'])) for n, f in backend.items()} }")
    time.sleep(1)
for name, fixture in backend.items():
    assert sorted(got[name]) == sorted(fixture["records"]), (
        f"{name}: records split or merged ({len(got[name])} entries, expected {len(fixture['records'])}); "
        f"unexpected: {[line[:160] for line in got[name] if line not in fixture['records']][:3]}")
    for line in got[name]:
        if line.startswith("{"):
            json.loads(line)
for name, fixture in backend.items():
    if not fixture["errors"]:
        continue
    query = urllib.parse.urlencode({
        "query": f'sum(count_over_time({{fixture_stream="{name}"}} | detected_level="error" [1h]))',
        "time": str(int(time.time()) + 1),
    })
    with opener.open(url + "/loki/api/v1/query?" + query, timeout=15) as response:
        result = json.load(response)
    count = int(float(result["data"]["result"][0]["value"][1])) if result["data"]["result"] else 0
    assert count == fixture["errors"], f"{name}: Loki detected {count} error records, expected {fixture['errors']}"
print(f"  ok   {len(backend)} backend streams: {sum(len(f['records']) for f in backend.values())} plain and ECS JSON records one entry each, "
      "stack traces reassembled, JSON never merged (also after plain records in one stream), ECS log.level detected as the Loki level")
