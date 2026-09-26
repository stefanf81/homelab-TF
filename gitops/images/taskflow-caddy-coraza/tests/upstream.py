#!/usr/bin/env python3
"""Counting echo upstream for the identity and rate-limit tests.

Every request (except /__count) increments a counter keyed by the X-Real-IP
header Caddy forwards, and echoes the identity headers back as JSON so tests can
assert what Caddy resolved. /__count returns the counters without incrementing,
which is how "did rejected requests reach the backend?" is checked.
"""

import http.server
import json
import threading

lock = threading.Lock()
counts: dict[str, int] = {}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        if self.path == "/__count":
            with lock:
                snapshot = dict(counts)
            self._send(200, snapshot)
            return

        identity = self.headers.get("X-Real-IP", "")
        with lock:
            counts[identity] = counts.get(identity, 0) + 1
        self._send(
            200,
            {
                "x_real_ip": identity,
                "x_forwarded_for": self.headers.get("X-Forwarded-For", ""),
                "cf_connecting_ip": self.headers.get("CF-Connecting-IP", ""),
                "path": self.path,
            },
        )

    def _send(self, status: int, payload) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        pass


def main() -> None:
    http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()


if __name__ == "__main__":
    main()
