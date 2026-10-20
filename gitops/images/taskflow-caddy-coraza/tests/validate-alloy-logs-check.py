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

truth = json.load(open(sys.argv[1]))["security"]
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
