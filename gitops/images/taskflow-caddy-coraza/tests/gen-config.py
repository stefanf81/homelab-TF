#!/usr/bin/env python3
"""Generate a runnable Caddyfile from a production WAF ConfigMap.

The production Caddyfile is used verbatim except for two substitutions:
  * the trusted_proxies list is replaced with the simulated proxy addresses;
  * the reverse_proxy upstream is replaced with the test upstream host.
The rate-limit.conf and exclusions ConfigMap keys are written next to it so the
imports resolve exactly as in production.
"""

import os
import re
import sys

import yaml


def main() -> int:
    src, outdir, waf, trusted, upstream_host = sys.argv[1:6]
    with open(src) as fh:
        docs = [d for d in yaml.safe_load_all(fh) if d]
    cm = next(d for d in docs if d.get("kind") == "ConfigMap")
    caddyfile = cm["data"]["Caddyfile"]

    caddyfile, n_trust = re.subn(
        r"trusted_proxies static .*?(?=\n\s+trusted_proxies_strict)",
        f"trusted_proxies static {trusted}",
        caddyfile,
        flags=re.S,
    )
    caddyfile, n_proxy = re.subn(
        r"reverse_proxy http://\S+",
        f"reverse_proxy http://{upstream_host}:8080",
        caddyfile,
    )
    if n_trust != 1 or n_proxy != 1:
        print(
            f"{src}: expected exactly one trusted_proxies and one reverse_proxy "
            f"substitution, got {n_trust}/{n_proxy}",
            file=sys.stderr,
        )
        return 1

    os.makedirs(os.path.join(outdir, "caddy"), exist_ok=True)
    os.makedirs(os.path.join(outdir, "coraza"), exist_ok=True)
    with open(os.path.join(outdir, "caddy", "Caddyfile"), "w") as fh:
        fh.write(caddyfile)
    with open(os.path.join(outdir, "caddy", "rate-limit.conf"), "w") as fh:
        fh.write(cm["data"]["rate-limit.conf"])
    with open(os.path.join(outdir, "coraza", f"{waf}-exclusions.conf"), "w") as fh:
        fh.write(cm["data"][f"{waf}-exclusions.conf"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
