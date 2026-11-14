#!/usr/bin/env python3
"""Shrink the shipped rate-limit zones so the behavioural tests run in seconds.

Only each zone's `events` and `window` values are rewritten; the zone names,
`key`, `match` blocks and `ipv6_prefix` stay exactly as the ConfigMap ships
them, so a production change to any of those is what the tests exercise.

usage: patch-rate-limit.py <rate-limit.conf> <window> <zone>=<events> [...]

The zones named on the command line must be exactly the zones in the file: a
renamed, added or removed zone fails here instead of silently going untested.
"""

import re
import sys


def main() -> int:
    path, window, *specs = sys.argv[1:]
    wanted = {}
    for spec in specs:
        name, _, events = spec.partition("=")
        wanted[name] = int(events)

    with open(path) as fh:
        text = fh.read()

    # Split at each `zone <name> {`; the text up to the next zone header (or the
    # end) holds that zone's directives, including any nested `match { ... }`.
    parts = re.split(r"(?m)^(\s*zone\s+(\S+)\s*\{)", text)
    head, rest = parts[0], parts[1:]
    found = []
    out = [head]
    for i in range(0, len(rest), 3):
        header, name, body = rest[i], rest[i + 1], rest[i + 2]
        found.append(name)
        if name not in wanted:
            break
        body, n_events = re.subn(r"(?m)^(\s*events\s+)\S+", rf"\g<1>{wanted[name]}", body, count=1)
        body, n_window = re.subn(r"(?m)^(\s*window\s+)\S+", rf"\g<1>{window}", body, count=1)
        if n_events != 1 or n_window != 1:
            print(f"{path}: zone {name} has no events/window line to patch", file=sys.stderr)
            return 1
        out.append(header + body)

    if sorted(found) != sorted(wanted):
        print(f"{path}: shipped zones {sorted(found)} differ from the zones under test {sorted(wanted)}; "
              "update tests/run-tests.sh together with the ConfigMap", file=sys.stderr)
        return 1

    with open(path, "w") as fh:
        fh.write("".join(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
