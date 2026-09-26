#!/usr/bin/env python3
"""Minimal forwarding proxy that appends the connecting peer to X-Forwarded-For.

This emulates how Cloudflare and Cilium's Envoy append the address they see, so
the identity tests exercise a realistic header chain:

    client -> edge (Cloudflare) -> envoy (Cilium) -> caddy -> upstream

Plain HTTP only; the trust-chain semantics under test do not depend on TLS.
"""

import argparse
import http.server
import urllib.error
import urllib.request


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream = ""
    client_header = ""

    def _forward(self) -> None:
        body = b""
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            body = self.rfile.read(length)

        peer = self.client_address[0]

        # Test hook: pretend this hop saw a different client address (e.g. an
        # IPv6 client behind Cloudflare) by reporting the value of a header
        # instead of the real TCP peer. Downstream trusted hops are still skipped
        # by Caddy's right-to-left walk, so the reported value is selected.
        if self.client_header:
            reported = (self.headers.get(self.client_header) or "").strip()
            if reported:
                peer = reported

        xff = self.headers.get("X-Forwarded-For")
        xff = f"{xff}, {peer}" if xff else peer

        req = urllib.request.Request(
            self.upstream.rstrip("/") + self.path,
            data=body or None,
            method=self.command,
        )
        for key, value in self.headers.items():
            if key.lower() in (
                "host",
                "content-length",
                "connection",
                "x-forwarded-for",
                "x-forwarded-proto",
            ):
                continue
            req.add_header(key, value)
        req.add_header("X-Forwarded-For", xff)
        req.add_header("X-Forwarded-Proto", "https")

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                self._relay(resp.status, resp.headers, resp.read())
        except urllib.error.HTTPError as err:
            self._relay(err.code, err.headers, err.read())

    def _relay(self, status: int, headers, data: bytes) -> None:
        self.send_response(status)
        for key, value in headers.items():
            if key.lower() in ("transfer-encoding", "connection", "content-length"):
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = _forward
    do_POST = _forward

    def log_message(self, *args) -> None:  # keep test output quiet
        pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", type=int, default=8080)
    parser.add_argument("--upstream", required=True)
    parser.add_argument(
        "--client-header",
        default="",
        help="header whose value is reported as this hop's client address",
    )
    args = parser.parse_args()

    Handler.upstream = args.upstream
    Handler.client_header = args.client_header
    server = http.server.ThreadingHTTPServer(("0.0.0.0", args.listen), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
