#!/usr/bin/env python3
"""Evaluate shipped discovery rules in real Alloy using synthetic pod metadata.

No Kubernetes API or log bodies are involved. Also render namespace-scoped RBAC
and verify discovery permissions and install ordering, without applying resources.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
RELEASE = ROOT / "gitops/monitoring/logging/alloy-release.yaml"
IMAGE = os.environ.get("ALLOY_IMAGE", "grafana/alloy:v1.21.3")


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs)


def yaml_docs(text):
    return json.loads(run("ruby", "-ryaml", "-rjson", "-e",
                          "puts JSON.generate(YAML.load_stream(STDIN.read).compact)", input=text))


def blocks(config):
    result, current = {}, []
    for line in config.splitlines():
        if not current and re.match(r'^\w[\w.]* "\w+" \{$', line):
            current = [line]
        elif current:
            current.append(line)
            if line == "}":
                result[current[0][:-2]] = "\n".join(current)
                current = []
    assert not current, "unterminated Alloy block"
    return result


def metadata(case, labels, namespace="taskflow", container="main", pod=None):
    target = {
        "fixture_id": case,
        "__meta_kubernetes_namespace": namespace,
        "__meta_kubernetes_pod_name": pod or case,
        "__meta_kubernetes_pod_container_name": container,
    }
    for key, value in labels.items():
        target["__meta_kubernetes_pod_label_" + re.sub(r"[^a-zA-Z0-9_]", "_", key)] = value
    return target


def literal(targets):
    return "[\n" + ",\n".join(
        "{" + ", ".join(f"{json.dumps(k)} = {json.dumps(v)}" for k, v in target.items()) + "}"
        for target in targets
    ) + ",\n]"


def value(v):
    if v["type"] == "array":
        return [value(x) for x in v["value"]]
    if v["type"] == "object":
        return {x["key"]: value(x["value"]) for x in v["value"]}
    return v.get("value")


def main():
    release = yaml_docs(RELEASE.read_text())[0]
    values = release["spec"]["values"]
    config = values["alloy"]["configMap"]["content"]
    source = blocks(config)
    namespaces = set()
    for name in ("pods", "abuseipdb", "platform"):
        names = re.search(r"names\s*=\s*(\[[^\]]*\])", source[f'discovery.kubernetes "{name}"'])
        namespaces.update(json.loads(names[1]))
    assert namespaces == set(values["rbac"]["namespaces"]), "RBAC and discovered namespaces must match"
    assert "trivy-system" in namespaces
    assert json.loads(re.search(r"names\s*=\s*(\[[^\]]*\])", source['discovery.kubernetes "pods"'])[1]) == ["taskflow"]
    assert values["rbac"]["clusterRules"] == [], "do not add cluster-wide log access"
    ks = yaml_docs((ROOT / "gitops/clusters/taskflow/monitoring-logging.yaml").read_text())[0]
    assert "trivy-operator" in [d["name"] for d in ks["spec"]["dependsOn"]], "Trivy namespace must exist before its Alloy Role"

    repo_docs = yaml_docs((ROOT / "gitops/monitoring/logging/repositories.yaml").read_text())
    chart = release["spec"]["chart"]["spec"]
    repo = next(r for r in repo_docs if r["metadata"]["name"] == chart["sourceRef"]["name"])
    with tempfile.TemporaryDirectory(prefix="alloy-discovery-") as tmp:
        tmp = Path(tmp)
        (tmp / "values.json").write_text(json.dumps(values))
        rendered = yaml_docs(run("helm", "template", "alloy", chart["chart"], "--repo", repo["spec"]["url"],
                                 "--version", chart["version"], "--namespace", "monitoring", "-f", str(tmp / "values.json")))
        roles = [r for r in rendered if r["kind"] == "Role"]
        assert {r["metadata"]["namespace"] for r in roles} == namespaces
        role = next(r for r in roles if r["metadata"]["namespace"] == "trivy-system")
        assert any("pods/log" in r.get("resources", []) and "get" in r.get("verbs", []) for r in role["rules"])
        bindings = [r for r in rendered if r["kind"] == "RoleBinding" and r["metadata"]["namespace"] == "trivy-system"]
        assert any(s.get("name") == "grafana-alloy" and s.get("namespace") == "monitoring"
                   for b in bindings for s in b.get("subjects", [])), "bind the actual Alloy service account"

        # Standard-only, legacy-only, and conflicting labels test precedence and
        # prevent the backend being double-shipped or WAF redaction being bypassed.
        fixtures = [
            metadata("legacy-backend", {"app": "taskflow-backend"}),
            metadata("standard-backend", {"app.kubernetes.io/name": "taskflow-backend"}),
            metadata("standard-wins", {"app": "old-name", "app.kubernetes.io/name": "taskflow-backend"}),
            metadata("frontend", {"app": "taskflow-frontend"}),
            metadata("postgres", {"app": "postgres-db"}),
            metadata("standard-app", {"app.kubernetes.io/name": "new-app"}),
            metadata("unlabelled", {}),
            metadata("waf", {"app": "taskflow-frontend-waf", "app.kubernetes.io/name": "taskflow-frontend-waf",
                              "app.kubernetes.io/component": "waf", "app.kubernetes.io/part-of": "taskflow",
                              "app.kubernetes.io/protects": "taskflow-frontend"}, container="waf"),
            metadata("legacy-waf", {"app": "taskflow-backend-waf"}),
            metadata("waf-misnamed", {"app.kubernetes.io/name": "taskflow-backend", "app.kubernetes.io/component": "waf"}),
        ]
        platform = [
            metadata("trivy-operator", {"app.kubernetes.io/name": "trivy-operator"}, "trivy-system"),
            metadata("trivy-server", {"app.kubernetes.io/name": "trivy-server"}, "trivy-system"),
            metadata("scan-results", {"app.kubernetes.io/managed-by": "trivy-operator"}, "trivy-system"),
            metadata("gateway", {"app.kubernetes.io/name": "loki"}, "monitoring", pod="loki-gateway-abcd"),
        ]
        selected = []
        for name in ("taskflow_identity", "taskflow_backend", "taskflow_apps", "taskflow_wafs", "platform"):
            block = source[f'discovery.relabel "{name}"']
            block = block.replace("discovery.kubernetes.pods.targets", literal(fixtures))
            block = block.replace("discovery.kubernetes.platform.targets", literal(platform))
            selected.append(block)
        (tmp / "config.alloy").write_text("\n\n".join(selected))
        container = None
        try:
            container = run("docker", "run", "-d", "--read-only", "--tmpfs", "/tmp",
                            "-p", "127.0.0.1::12345", "-v", f"{tmp / 'config.alloy'}:/etc/alloy/config.alloy:ro",
                            IMAGE, "run", "--server.http.listen-addr=0.0.0.0:12345",
                            "--storage.path=/tmp/alloy", "/etc/alloy/config.alloy").strip()
            port = json.loads(run("docker", "inspect", container))[0]["NetworkSettings"]["Ports"]["12345/tcp"][0]["HostPort"]
            outputs = {}
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                state = json.loads(run("docker", "inspect", container))[0]["State"]
                assert state["Running"], "Alloy exited while loading the fixture config"
                try:
                    for name in ("taskflow_backend", "taskflow_apps", "taskflow_wafs", "platform"):
                        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v0/web/components/discovery.relabel.{name}", timeout=5) as response:
                            detail = json.load(response)
                        assert detail["health"]["state"] == "healthy", detail
                        outputs[name] = value(next(x["value"] for x in detail["exports"] if x["name"] == "output"))
                    break
                except (OSError, urllib.error.URLError):
                    time.sleep(0.2)
            assert len(outputs) == 4, "Alloy did not export all discovery outputs"
            ids = {name: {t["fixture_id"] for t in targets} for name, targets in outputs.items()}
            assert ids["taskflow_backend"] == {"legacy-backend", "standard-backend", "standard-wins"}, ids
            assert ids["taskflow_apps"] == {"frontend", "postgres", "standard-app"}, ids
            assert ids["taskflow_wafs"] == {"waf"}, ids
            assert ids["platform"] == {"trivy-operator", "trivy-server"}, ids
            for name in ("taskflow_backend", "taskflow_apps"):
                assert f"targets = discovery.relabel.{name}.output" in source[f'loki.source.kubernetes "{name}"']
                for target in outputs[name]:
                    assert target["job"] == "taskflow-app" and target["namespace"] == "taskflow"
                    assert target["application"] and target["pod"] and target["container"]
            assert all(t["job"] == "cluster-platform" and t["namespace"] == "trivy-system" for t in outputs["platform"])
            print("OK real Alloy: legacy/standard routing, backend isolation, WAF guards, Trivy diagnostics (not scan payloads)")
            print("OK Helm: namespace-scoped Trivy log RBAC and namespace creation dependency")
        except Exception:
            if container:
                logs = subprocess.run(["docker", "logs", container], text=True, capture_output=True)
                print(logs.stdout, logs.stderr)
            raise
        finally:
            if container:
                subprocess.run(["docker", "rm", "-f", container], capture_output=True, check=False)


if __name__ == "__main__":
    main()
