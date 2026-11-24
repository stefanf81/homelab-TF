#!/usr/bin/env python3
"""One-shot HTTP client used by the tests; prints a JSON result to stdout.

Usage: client.py [-X METHOD] [--body-bytes N] <url> [Header: value ...]
Output: {"status": <int>, "retry_after": <str|null>, "body": <str>}

Without -X the request is a GET. POST, PUT and PATCH send a small JSON body, or
one of exactly N bytes with --body-bytes.
"""

import json
import sys
import urllib.error
import urllib.request


def main() -> int:
    args = sys.argv[1:]
    method = "GET"
    body_bytes = 0
    while args[0] in ("-X", "--body-bytes"):
        if args[0] == "-X":
            method = args[1]
        else:
            body_bytes = int(args[1])
        args = args[2:]
    url = args[0]
    headers = {}
    for raw in args[1:]:
        name, _, value = raw.partition(":")
        headers[name.strip()] = value.strip()

    body = None
    if method in ("POST", "PUT", "PATCH"):
        body = b'{"test": true}'
        if body_bytes:
            body = b'{"pad": "' + b"x" * (body_bytes - 11) + b'"}'
        headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
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
