#!/usr/bin/env python3
"""One-shot HTTP client used by the tests; prints a JSON result to stdout.

Usage: client.py <url> [Header: value ...]
Output: {"status": <int>, "retry_after": <str|null>, "body": <str>}
"""

import json
import sys
import urllib.error
import urllib.request


def main() -> int:
    url = sys.argv[1]
    headers = {}
    for raw in sys.argv[2:]:
        name, _, value = raw.partition(":")
        headers[name.strip()] = value.strip()

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            print(
                json.dumps(
                    {
                        "status": resp.status,
                        "retry_after": resp.headers.get("Retry-After"),
                        "body": resp.read().decode(errors="replace"),
                    }
                )
            )
    except urllib.error.HTTPError as err:
        print(
            json.dumps(
                {
                    "status": err.code,
                    "retry_after": err.headers.get("Retry-After"),
                    "body": err.read().decode(errors="replace"),
                }
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
