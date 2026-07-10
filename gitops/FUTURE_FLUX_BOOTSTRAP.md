# TaskFlow bootstrap checklist

This is the end-to-end path from a fresh Proxmox VM to the current TaskFlow
GitOps state.

## 0. Prereqs

- A remote Git repository containing this tree
- `tofu`, `kubectl`, `flux`, and the Cilium CLI on your workstation
- `key.txt` present locally for the SOPS age secret

## 1. Provision the VM and fetch kubeconfig

```bash
make init
make provision
make kubeconfig
```

## 2. Install Cilium on the k3s cluster

The VM boots k3s without Flannel, so Cilium must be installed on top.

```bash
export KUBECONFIG=$PWD/kubeconfig.yaml
cilium install --version 1.16.1
cilium status --wait
```

If the node stays NotReady, fix Cilium before moving on.

## 3. Seed the Flux SOPS key once

Flux decrypts `*-secrets.yaml` via the `sops-age` Secret in `flux-system`.

```bash
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=key.txt
```

## 4. Bootstrap Flux

The bootstrap manifests already live in `gitops/clusters/taskflow/flux-system/`.

```bash
kubectl apply -k gitops/clusters/taskflow/flux-system
flux reconcile source git flux-system
flux reconcile kustomization flux-system -n flux-system
```

## 5. Reconcile the platform and app layers

```bash
flux reconcile kustomization infra-controllers -n flux-system
flux reconcile kustomization infra-configs -n flux-system
flux reconcile kustomization taskflow-app -n flux-system
```

## 6. Verify

```bash
kubectl get pods -A
kubectl get gateway,httproute -n taskflow
kubectl get secret -n taskflow db-secret backend-secret
```
