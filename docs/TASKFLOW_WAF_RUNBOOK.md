# Taskflow WAF Runbook

## Components

- `taskflow-frontend-waf` receives `www.jokelab.dev/` traffic.
- `taskflow-backend-waf` receives `www.jokelab.dev/api` traffic.
- Both WAFs use Caddy `2.11.4`, Coraza Caddy `v2.5.0`, and OWASP CRS.
- Both WAFs start with `SecRuleEngine DetectionOnly` and paranoia level 1.
- Loki runs as one monolithic replica in `monitoring` with 30-day retention.
- Alloy collects only pods labelled as Taskflow WAFs and sends them to Loki.

## Build the WAF image

The repository intentionally contains only the Dockerfile, not a CI workflow.
Build and publish the image manually:

```bash
docker build \
  -t ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.5.0 \
  gitops/images/taskflow-caddy-coraza

docker push ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.5.0

docker run --rm \
  ghcr.io/stefanf81/taskflow-caddy-coraza:2.11.4-coraza2.5.0 \
  list-modules | grep 'http.handlers.waf'
```

Replace the image reference in both WAF Deployments with the digest returned by
`docker buildx imagetools inspect` before relying on the deployment in production.

## Reconcile

```bash
flux reconcile kustomization taskflow-app -n flux-system --with-source
flux reconcile kustomization monitoring -n flux-system --with-source
flux reconcile kustomization monitoring-logging -n flux-system --with-source
```

Check readiness:

```bash
kubectl -n taskflow get deploy,svc,pod taskflow-frontend-waf taskflow-backend-waf
kubectl -n monitoring get helmrelease loki alloy
kubectl -n monitoring get pvc,pod -l app.kubernetes.io/part-of=taskflow-observability
kubectl get httproute -n taskflow taskflow-route -o yaml
```

The route must report `Accepted=True` and `ResolvedRefs=True`.

## Internal tests

Test each WAF before relying on the public route:

```bash
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -i http://taskflow-frontend-waf.taskflow.svc.cluster.local:8080/

kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -i http://taskflow-backend-waf.taskflow.svc.cluster.local:8080/api
```

Use a harmless detection request against a real backend path only after confirming
that the path is safe. DetectionOnly must return the upstream response rather than
block it:

```bash
kubectl run curl-test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -i 'http://taskflow-backend-waf.taskflow.svc.cluster.local:8080/api?test=1%20UNION%20SELECT%201'
```

Inspect logs separately:

```bash
kubectl logs -n taskflow deploy/taskflow-frontend-waf
kubectl logs -n taskflow deploy/taskflow-backend-waf
kubectl logs -n monitoring deploy/alloy
```

In Grafana Explore, select the `Loki` datasource and query:

```logql
{job="coraza-waf", application="taskflow-frontend"}
{job="coraza-waf", application="taskflow-backend"}
```

## Blocking rollout

Blocking is intentionally independent. Tune and enable one application at a time:

1. Observe frontend detections and add narrow frontend exclusions only.
2. Change only the frontend `SecRuleEngine` to `On`.
3. Observe frontend behavior and roll back if required.
4. Tune backend detections and add narrow backend exclusions only.
5. Change only the backend `SecRuleEngine` to `On`.

## Rollback

To roll back public traffic while keeping the WAF workloads available, restore only
the two `backendRefs` in `gitops/apps/taskflow/httproute.yaml`:

- `/api` -> `backend:8080`
- `/` -> `frontend:8080`

Then reconcile `taskflow-app`. To disable one WAF without changing the other, restore
only its route backend and leave the other WAF route unchanged.

To remove logging, remove `monitoring-logging.yaml` from the cluster Kustomization
and reconcile after verifying that Loki data retention requirements are understood.
The Loki PVC uses the `proxmox-csi` reclaim policy and is retained independently of
the Helm release.

## Security notes

- Original application Services remain ClusterIP.
- Gateway access is allowed only to the WAF workloads.
- Each WAF can reach only its corresponding application Service and cluster DNS.
- Coraza audit parts exclude request headers and bodies.
- Caddy access logs redact credentials and selected sensitive query parameters.
- Loki and Alloy have no Gateway, LoadBalancer, or public route.
