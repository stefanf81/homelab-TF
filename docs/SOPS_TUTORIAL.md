# Mozilla SOPS & age Secrets Management Guide

This guide explains how **Mozilla SOPS (Secrets Operations)** and **`age`** are configured and used in this project to manage Kubernetes secrets securely within Git.

---

## 1. Overview

In GitOps, keeping plain-text secrets in a Git repository is a major security vulnerability. To solve this without adding heavy infrastructure overhead (like HashiCorp Vault), this project uses **Mozilla SOPS** with **`age`** (a modern, simple, and secure alternative to GPG).

### How it Works:
1. **Asymmetric Encryption:** Secrets are encrypted using a public `age` key. Anyone with access to the public key can encrypt secrets.
2. **Encrypted in Git:** Encrypted secrets are stored in Git. Only the sensitive values are encrypted; the structural metadata of the YAML file (like `apiVersion`, `kind`, and `metadata.name`) remains in plain text. This allows GitOps engines like Flux to track changes easily.
3. **Decryption at Cluster Edge:** Only authorized developers (with the local `key.txt` private key) and the Kubernetes cluster (via a Secret named `sops-age` inside the `flux-system` namespace) can decrypt these secrets.

---

## 2. Installation

To view, edit, or create secrets locally, you must install both `sops` and `age` on your workstation.

### macOS (Homebrew)
```bash
brew install sops age
```

### Linux (Debian/Ubuntu)
```bash
# Install age
sudo apt update && sudo apt install -y age

# Install sops
sudo curl -Lo /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.9.0/sops-v3.9.0.linux.amd64
sudo chmod +x /usr/local/bin/sops
```

### Windows (Chocolatey or Scoop)
```powershell
choco install sops age
# OR
scoop install sops age
```

---

## 3. How SOPS is Configured in This Project

### The SOPS Rules (`.sops.yaml`)
In the root of the project, a `.sops.yaml` configuration file defines which files should be encrypted and which keys should be used:

```yaml
creation_rules:
  - path_regex: .*-secrets\.yaml$
    age: "age14tnw8z266962s0guenumuyqht55kt68grrx204wsle8u8p8ph9vscxnm22"
```

* **`path_regex`**: Any file ending in `-secrets.yaml` is automatically matched by SOPS.
* **`age`**: This is the public recipient key. When you run a `sops` encryption command, it automatically uses this public key to encrypt the files.

### Key Files in this Project:
1. **`.sops.yaml`**: Configures the rules. **Safe to commit to Git.**
2. **`key.txt`**: Contains your local private key. **NEVER COMMIT `key.txt` TO GIT.** It is explicitly ignored in `.gitignore`.
3. **`gitops/apps/taskflow/taskflow-secrets.yaml`**: The encrypted application secrets.
4. **`gitops/infrastructure/controllers/proxmox-csi/proxmox-csi-secrets.yaml`**: Proxmox CSI storage secrets.
5. **`gitops/monitoring/platform/grafana-secrets.yaml`**: Grafana admin secrets.

---

## 4. Common Operations (Cheat Sheet)

### A. Generating a New Key (If setting up from scratch)
If you need to rotate keys or set up a new environment:
```bash
# Generate a new age keypair and output it to key.txt
age-keygen -o key.txt
```
*The command will output the public key to stdout (which you copy into `.sops.yaml`) and save both the public and private keys in `key.txt`.*

### B. Configuring SOPS to use your Private Key
Before running any decrypt or edit commands, tell SOPS where your private key resides:
```bash
export SOPS_AGE_KEY_FILE=$PWD/key.txt
```
*(You can also add this export to your `~/.zshrc` or `~/.bashrc` pointing to the absolute path of your key).*

### C. Encrypting a New Secrets File
1. Create a normal plain-text Kubernetes Secret template ending in `-secrets.yaml` (e.g. `test-secrets.yaml`):
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: my-app-secret
     namespace: taskflow
   stringData:
     DATABASE_PASSWORD: super-secret-password
   ```
2. Encrypt the file in-place:
   ```bash
   sops -e -i path/to/test-secrets.yaml
   ```
   *The file is now encrypted and safe to commit to Git.*

### D. Editing an Existing Encrypted File
To edit an already encrypted file in-place using your default terminal editor (e.g., Vim, VS Code, Nano):
```bash
sops gitops/apps/taskflow/taskflow-secrets.yaml
```
When you save and exit the editor, SOPS automatically re-encrypts the file.

### E. Decrypting a Secret to Standard Out
To view the raw plain-text secret without modifying the file:
```bash
sops -d gitops/apps/taskflow/taskflow-secrets.yaml
```

### F. Comparing Changes (Git Diff)
To make `git diff` show decrypted versions of modified secret files instead of unreadable binary diffs, configure Git to use SOPS for diffing:
```bash
git config diff.sops.textconv "sops -d"
```

---

## 5. GitOps & Flux CD Integration

Flux CD has native integration with Mozilla SOPS, allowing it to decrypt your files directly at the cluster boundary before applying them.

### Step 1: Seed the Private Key in Kubernetes
For Flux to decrypt secrets, you must load your local `key.txt` into the cluster as a Kubernetes Secret. This is a one-time setup step done during cluster bootstrap:

```bash
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=key.txt
```

### Step 2: Flux Decryption Configuration
Your GitOps Sync Kustomization manifests (located under `gitops/clusters/taskflow/`) are configured to use SOPS and reference this cluster secret:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: taskflow-app
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./gitops/apps/taskflow
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

---

## 6. Troubleshooting

### Error: `SOPS_AGE_KEY_FILE keys were not found`
* **Cause**: SOPS cannot find your private key.
* **Fix**: Ensure `key.txt` exists in your workspace and export the path:
  ```bash
  export SOPS_AGE_KEY_FILE=$PWD/key.txt
  ```

### Error: `MAC mismatch`
* **Cause**: The metadata check failed because the file was edited or modified outside of the SOPS CLI (e.g., editing the encrypted file directly with a standard editor instead of running `sops <file>`).
* **Fix**: Revert your Git changes to the last clean encrypted state. Only edit files using the `sops <file>` command.

### Flux fails to apply secrets
* **Cause**: Flux does not have the correct private key in the cluster, or the `sops-age` secret is missing.
* **Fix**:
  1. Check Flux Kustomization logs:
     ```bash
     flux logs --level=error
     ```
  2. Verify the secret exists in the cluster:
     ```bash
     kubectl get secret sops-age -n flux-system -o yaml
     ```
  3. Ensure the key inside the secret matches the key that encrypted the files.
