#!/usr/bin/env python3
"""False-positive regression test: legitimate TaskFlow requests through the WAF.

Usage: benign-corpus.py <frontend|backend> <base-url>
       docker logs <waf> | benign-corpus.py --rules

Sends every case of the given WAF through the simulated Cloudflare edge, each
from its own client address (X-Test-Client), so the rate limiter never answers
and every status is the WAF's own decision. Each case pins its outcome:

  PASS  the request must reach the upstream (200 from the echo server)
  FP    a known false positive: the WAF must still answer 403. These are
        legitimate requests that the shipped rule set blocks today; they are
        listed so a rule-set update that changes *anything* fails CI, in both
        directions. A new 403 is a new false positive. A known false positive
        that starts passing means the update changed detection: read the
        release notes, then move the case to PASS.

Paths, field names and methods are the ones taskflow-enterprise sends
(Angular core/api/*.ts and the Spring request records). The free text is
deliberately punctuation-heavy, like real names, reviews and admin text.
Prints one line per case and exits 1 on any mismatch.
"""

import json
import re
import sys
import urllib.error
import urllib.request

PUBLIC_ID = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
JWT = (
    "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJzdWIiOiI0MiIsImlzcyI6InRhc2tmbG93IiwiYXVkIjoidGFza2Zsb3ctYXBpIiwiZXhwIjoxNzk1MzEyNjM3fQ."
    "c2lnbmF0dXJlLXBsYWNlaG9sZGVyLW5vdC1yZWFsLWJ1dC1sb25nLWVub3VnaC10by1sb29rLWxpa2Utb25l"
)
XSRF = "3f9b2c1e-7a55-4c0e-9d8e-2b1a6f4c7d10"
BROWSER = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/142.0.0.0 Safari/537.36",
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "de-DE,de;q=0.9,en;q=0.8",
    "Accept-Encoding": "gzip, deflate, br",
    "Referer": "https://www.example.org/customer/book",
    "Origin": "https://www.example.org",
    "Cookie": f"access_token={JWT}; refresh_token=aB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1gI3kM5oQ7sU9w; "
    f"XSRF-TOKEN={XSRF}; taskflow_session=1",
    "X-XSRF-TOKEN": XSRF,
}
SPA = {"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
MOBILE = {"Authorization": f"Bearer {JWT}", "User-Agent": "TaskFlow/1.8.0 (Android 16) okhttp/5.3.0"}

PASS = "PASS"


def fp(rules, todo):
    """A known false positive: still 403 today. `rules` as seen in the audit log."""
    return {"rules": rules, "todo": todo}


# (waf, method, path, json body or None, extra headers, expectation)
CASES = [
    # Frontend WAF: the SPA and its static files (GET/HEAD only).
    ("frontend", "GET", "/", None, SPA, PASS),
    ("frontend", "HEAD", "/", None, SPA, PASS),
    ("frontend", "GET", "/main-K7Q2ZP4A.js", None, {}, PASS),
    ("frontend", "GET", "/styles-X3B5T2LQ.css", None, {}, PASS),
    ("frontend", "GET", "/favicon.ico", None, {}, PASS),
    ("frontend", "GET", "/customer/book?barber=Alex%20the%20Barber&date=2026-12-01", None, SPA, PASS),
    ("frontend", "GET", "/admin", None, SPA, PASS),
    # Backend WAF: auth.
    ("backend", "GET", "/api/v1/auth/csrf", None, {}, PASS),
    ("backend", "GET", "/api/v1/auth/me", None, {}, PASS),
    ("backend", "POST", "/api/v1/auth/login",
     {"username": "anna.o'brien@example.com", "password": "Tr0ub4dor&3-horse;battery"}, {}, PASS),
    ("backend", "POST", "/api/v1/auth/login",
     {"username": "jürgen.müller@example.de", "password": "p@ss w0rd' OR so"}, {}, PASS),
    ("backend", "POST", "/api/v1/auth/register",
     {"fullName": "Zoë D'Angelo-Öztürk", "email": "new.user+shop@example.com",
      "password": "Sommer2026!#$%", "phone": "+49 (0)151 2345-6789"}, {}, PASS),
    ("backend", "POST", "/api/v1/auth/refresh", None, {}, PASS),
    ("backend", "POST", "/api/v1/auth/mobile/login",
     {"username": "sean@example.ie", "password": "Gr33n-Fields_2026"}, MOBILE, PASS),
    ("backend", "POST", "/api/v1/auth/logout", None, {}, PASS),
    # Booking (guest).
    ("backend", "GET", "/api/v1/appointments/public/shop", None, {}, PASS),
    ("backend", "GET", "/api/v1/appointments/public/busy-slots"
     "?barberName=Alex%20the%20Barber&bookingDate=2026-12-01&serviceType=Classic%20Haircut", None, {}, PASS),
    ("backend", "POST", "/api/v1/appointments",
     {"customerName": "Seán O'Connor", "customerEmail": "sean@example.ie", "customerPhone": "+353 87 123 4567",
      "barberName": "Alex the Barber", "bookingDate": "2026-12-01", "bookingTime": "14:30",
      "serviceType": "Cut & Shave (Deluxe)"},
     {"Idempotency-Key": "0b7e6c0e-5d55-4d2a-9f43-1b2a3c4d5e6f"},
     fp("932236", "TODO(W-6): every booking of a service named like this is blocked. Exclude "
        "ARGS:json.serviceType from 932236 on POST /api/v1/appointments, or keep such names "
        "out of the catalog (the catalog case below blocks creating it)")),
    # The seeded catalog (V5__create_service_catalog.sql) names a service "Beard Trim & Shave";
    # its name travels as serviceType in every booking of it.
    ("backend", "GET", "/api/v1/appointments/public/busy-slots"
     "?barberName=Alex%20the%20Barber&bookingDate=2026-12-01&serviceType=Beard%20Trim%20%26%20Shave", None, {}, PASS),
    ("backend", "POST", "/api/v1/appointments",
     {"customerName": "Lena Groß", "customerEmail": "lena@example.de", "customerPhone": "+49 170 1234567",
      "barberName": "No Preference", "bookingDate": "2026-12-02", "bookingTime": "10:00",
      "serviceType": "Beard Trim & Shave"}, {}, PASS),
    ("backend", "PUT", f"/api/v1/appointments/public/cancel/{PUBLIC_ID}", {"email": "sean@example.ie"}, {}, PASS),
    ("backend", "POST", f"/api/v1/appointments/public/reschedule/{PUBLIC_ID}/availability",
     {"email": "sean@example.ie", "bookingDate": "2026-12-03"}, {}, PASS),
    ("backend", "PUT", f"/api/v1/appointments/public/reschedule/{PUBLIC_ID}",
     {"email": "sean@example.ie", "bookingDate": "2026-12-03", "bookingTime": "09:00"}, {}, PASS),
    ("backend", "POST", f"/api/v1/appointments/public/calendar/{PUBLIC_ID}", {"email": "sean@example.ie"}, {}, PASS),
    # Customer portal.
    ("backend", "GET", "/api/v1/customer/appointments?page=0&size=10", None, {}, PASS),
    ("backend", "GET", f"/api/v1/customer/appointments/{PUBLIC_ID}/availability?bookingDate=2026-12-03",
     None, {}, PASS),
    ("backend", "PUT", f"/api/v1/customer/appointments/{PUBLIC_ID}/reschedule",
     {"bookingDate": "2026-12-03", "bookingTime": "09:00"}, {}, PASS),
    ("backend", "DELETE", f"/api/v1/customer/appointments/{PUBLIC_ID}", None, {}, PASS),
    # Reviews: the one free-text field a guest fills in.
    ("backend", "POST", f"/api/v1/reviews/public/{PUBLIC_ID}",
     {"rating": 5, "customerEmail": "sean@example.ie",
      "comment": "Best barber in town!!! 10/10 would book again :) He's fast, friendly & exact."},
     {}, fp("932200", "TODO(W-6): review comments are free text; request-scoped exclusion for "
                      "ARGS:json.comment on POST /api/v1/reviews/public/*")),
    ("backend", "POST", f"/api/v1/reviews/public/{PUBLIC_ID}",
     {"rating": 4, "customerEmail": "lena@example.de",
      "comment": "Bitte kurz & knapp; Seiten 3mm, oben 'nur Spitzen'. Komme evtl. 5-10 min später (Bahn)!"},
     {}, fp("942200", "TODO(W-6): as above (ARGS:json.comment)")),
    ("backend", "POST", f"/api/v1/reviews/public/{PUBLIC_ID}",
     {"rating": 3, "customerEmail": "kim@example.com",
      "comment": "Select a time after 5pm if possible; or call me -- thanks <3"},
     {}, fp("932236 942131 942440", "TODO(W-6): as above (ARGS:json.comment)")),
    ("backend", "GET", "/api/v1/reviews/public/barber-ratings", None, {}, PASS),
    # Admin.
    ("backend", "GET", "/api/v1/appointments?page=0&size=20&status=APPROVED&search=m%C3%BCller", None, {}, PASS),
    ("backend", "GET", "/api/v1/appointments?page=0&size=20&search=O%27Connor", None, {}, PASS),
    ("backend", "PUT", "/api/v1/appointments/42", {"status": "APPROVED"}, {}, PASS),
    ("backend", "DELETE", "/api/v1/appointments/42", None, {}, PASS),
    ("backend", "POST", "/api/v1/catalog",
     {"name": "Cut & Shave (Deluxe)", "category": "hair",
      "description": "Wash, cut, hot-towel shave -- 45 min. Kids under 12: 50% off!",
      "price": 45.00, "durationMinutes": 45},
     {}, fp("932236 942440", "TODO(W-6): admin-only free text; exclusion for ARGS:json.name and "
                             "ARGS:json.description on /api/v1/catalog")),
    ("backend", "PUT", "/api/v1/catalog/7",
     {"name": "Beard Trim", "category": "beard", "description": "Shape & line-up; incl. hot towel.",
      "price": 19.50, "durationMinutes": 20}, {}, PASS),
    ("backend", "PUT", "/api/v1/catalog/3",
     {"name": "Beard Trim & Shave", "category": "beard",
      "description": "Detail beard lineup, hot steam towel treatment, aromatic pre-shave oil massage, and soothing trim.",
      "price": 18.00, "durationMinutes": 25}, {}, PASS),
    ("backend", "PUT", "/api/v1/catalog/5",
     {"name": "The Executive Package", "category": "combo",
      "description": "The ultimate royal experience: Classic Haircut, full Beard Shave, facial wash, "
                     "and essential-oil head massage.",
      "price": 40.00, "durationMinutes": 60}, {}, PASS),
    ("backend", "POST", "/api/v1/barbers",
     {"name": "José \"Pepe\" Martínez", "email": "pepe@example.es", "phone": "+34 612 345 678"}, {}, PASS),
    ("backend", "POST", "/api/v1/barbers/3/time-off",
     {"startDate": "2026-12-24", "endDate": "2026-12-26", "reason": "Weihnachten / X-mas"}, {}, PASS),
    ("backend", "POST", "/api/v1/barbers/3/time-off",
     {"startDate": "2027-01-04", "endDate": "2027-01-05", "reason": "Can't make it; I'm ill (fever > 39°C). Sorry!"},
     {}, fp("942131", "TODO(W-6): admin-only free text; exclusion for ARGS:json.reason on "
                      "POST /api/v1/barbers/*/time-off")),
    ("backend", "GET", "/api/v1/notifications", None, {}, PASS),
    ("backend", "POST", "/api/v1/telemetry", {"platform": "WEB", "route": "BOOKING", "name": "LCP", "value": 1834.5},
     {}, PASS),
]


def run(waf: str, base: str) -> int:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    mismatches = []
    selected = [(i, c) for i, c in enumerate(CASES, 1) if c[0] == waf]
    for i, (_, method, path, body, extra, expect) in selected:
        headers = dict(BROWSER)
        headers.update(extra)
        # One client address per case (the edge reports it as the client), and
        # a case number the audit log carries for attribution.
        headers["X-Test-Client"] = f"198.51.100.{i}"
        headers["X-Corpus-Case"] = str(i)
        data = None
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode()
            headers["Content-Type"] = "application/json"
        elif method in ("POST", "PUT"):
            data = b""
        req = urllib.request.Request(base + path, data=data, method=method, headers=headers)
        try:
            with opener.open(req, timeout=20) as resp:
                status = resp.status
        except urllib.error.HTTPError as err:
            status = err.code
        want = 200 if expect == PASS else 403
        label = "PASS" if expect == PASS else "FP  "
        ok = status == want
        print(f"{'ok  ' if ok else 'FAIL'} case {i:2d} {label} got {status} want {want}  {method} {path[:80]}")
        if not ok:
            mismatches.append((i, method, path, status, expect))
    print(f"{waf}: {len(selected)} cases, "
          f"{sum(1 for _, c in selected if c[5] != PASS)} known false positives, {len(mismatches)} mismatches")
    for i, method, path, status, expect in mismatches:
        if expect == PASS:
            print(f"  case {i}: NEW FALSE POSITIVE ({status}) {method} {path}: a legitimate request is blocked."
                  " Find the rule in the audit log (X-Corpus-Case) and add a request-scoped exclusion,"
                  " or hold the rule-set update.")
        else:
            print(f"  case {i}: known false positive now gets {status} ({method} {path}); detection changed."
                  f" Read the release notes, then mark the case PASS (was: {expect['rules']}).")
    return 1 if mismatches else 0


def rules_from_audit_log(lines) -> int:
    """--rules: read the WAF container's log on stdin and print, per corpus case
    with an audit record, the CRS rule IDs that matched. This is the input for an
    exclusion (CORAZA_CONFIGURATION.md, "Exclusion Files")."""
    matched = {}
    for line in lines:
        line = line.strip()
        if not line.startswith("{") or '"x-corpus-case"' not in line:
            continue
        try:
            record = json.loads(line)
            case = record["transaction"]["request"]["headers"]["x-corpus-case"][0]
        except (ValueError, KeyError, IndexError, TypeError):
            continue
        ids = matched.setdefault(int(case), set())
        for message in record.get("messages") or []:
            ids.update(re.findall(r'\[id "(\d+)"\]', message.get("error_message") or ""))
    for case in sorted(matched):
        print(f"  audit: case {case:2d} matched rules {' '.join(sorted(matched[case], key=int))}")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--rules"]:
        raise SystemExit(rules_from_audit_log(sys.stdin))
    if len(sys.argv) != 3 or sys.argv[1] not in ("frontend", "backend"):
        print(__doc__, file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(run(sys.argv[1], sys.argv[2].rstrip("/")))
