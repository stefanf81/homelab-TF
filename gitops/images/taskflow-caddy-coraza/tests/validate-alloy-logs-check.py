#!/usr/bin/env python3
"""Check redaction and bounded method labels after the real Alloy -> Loki path.

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
            assert stream["stream"].get("method") == truth[key]["method"], f"unbounded/wrong method label: {key}"
            seen[key] = record
    if len(seen) == len(truth):
        break
    if time.monotonic() >= deadline:
        raise AssertionError(f"missing fixture records: {sorted(set(truth) - set(seen))}")
    time.sleep(1)
print(f"  ok   {len(seen)} audit fixtures: secrets removed, valid JSON, evidence preserved, bounded methods")

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
