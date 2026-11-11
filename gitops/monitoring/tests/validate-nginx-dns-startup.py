#!/usr/bin/env python3
"""Start the pinned frontend with networking disabled.

Static files must be served despite an unreachable DNS server and backend.
This tests startup resilience, not runtime DNS recovery or upstream authorization.
Uses only disposable local containers; never connects to a Kubernetes cluster.

Loki no longer has an nginx gateway to start (clients use the Loki Service
directly); validate-startup-scope.rb, run first below, checks that it stays so.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import time


HERE = Path(__file__).resolve().parent


def docker(*args, timeout=120):
    return subprocess.run(
        ["docker", *args], text=True, capture_output=True, check=True, timeout=timeout
    ).stdout.strip()


def run_args(config, destination):
    return [
        "--platform", "linux/amd64", "--network", "none", "--read-only",
        "--memory", "256m", "--cpus", "1", "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "--tmpfs", "/tmp:rw,noexec,nosuid,mode=1777",
        "--tmpfs", "/var/run:rw,noexec,nosuid,mode=1777",
        "--tmpfs", "/var/cache/nginx:rw,noexec,nosuid,mode=1777",
        "-v", f"{config}:{destination}:ro",
    ]


def check_old_config_fails(image, config, destination):
    # A negative control proves this network-disabled test actually exercises the
    # old boot-time lookup, rather than succeeding because external DNS works.
    result = subprocess.run(
        ["docker", "run", "--rm", *run_args(config, destination), image, "nginx", "-t"],
        capture_output=True, text=True, timeout=60,
    )
    if result.returncode == 0 or "host not found" not in result.stderr:
        raise RuntimeError(f"old config did not fail for the expected DNS reason: {result.stderr}")
    print(f"OK negative control {image}: old config fails on boot-time DNS lookup")


def check_startup(image, config, destination, endpoint):
    container = None
    try:
        container = docker(
            "run", "-d", *run_args(config, destination), image,
        )
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            state = json.loads(docker("inspect", container))[0]["State"]
            if not state["Running"]:
                raise RuntimeError(f"{image} exited before serving without DNS")
            response = subprocess.run(
                ["docker", "exec", container, "wget", "-q", "-O", "/dev/null",
                 "-T", "2", f"http://127.0.0.1:8080{endpoint}"],
                capture_output=True, text=True, timeout=10,
            )
            if response.returncode == 0:
                print(f"OK {image}: {endpoint} responds with DNS/backend unreachable")
                return
            time.sleep(0.5)
        raise RuntimeError(f"{image} did not serve {endpoint} without DNS")
    except Exception:
        if container:
            logs = subprocess.run(["docker", "logs", container], capture_output=True, text=True)
            print(logs.stdout)
            print(logs.stderr)
        raise
    finally:
        if container:
            subprocess.run(["docker", "rm", "-f", container], capture_output=True, check=False)


def main():
    with tempfile.TemporaryDirectory(prefix="nginx-dns-startup-") as tmp:
        subprocess.run(["ruby", str(HERE / "validate-startup-scope.rb"), "--fixtures", tmp], check=True)
        fixtures = Path(tmp)
        images = json.loads((fixtures / "images.json").read_text())
        old_frontend = fixtures / "old-frontend.conf"
        old_frontend.write_text("server backend.taskflow.svc.cluster.local:8080;\n")
        check_old_config_fails(images["frontend"], old_frontend, "/etc/nginx/upstream-server.conf")
        check_startup(images["frontend"], fixtures / "frontend-upstream.conf", "/etc/nginx/upstream-server.conf", "/index.html")


if __name__ == "__main__":
    main()
