# Secrets with SOPS and age

Every Kubernetes Secret in `gitops/` is committed encrypted with
[SOPS](https://github.com/getsops/sops) (a CNCF project) and an
[age](https://github.com/FiloSottile/age) key. Flux decrypts the files in the cluster
just before applying them. This document covers how that is wired in this repository,
the everyday commands, key rotation, and what to check when a Kustomization fails on an
encrypted file.

---

## 1. How it is set up here

### Encryption rules (`.sops.yaml`)

```yaml
creation_rules:
  - path_regex: .*-secrets\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: "age14tnw8z266962s0guenumuyqht55kt68grrx204wsle8u8p8ph9vscxnm22"
```

* **`path_regex`**: any file ending in `-secrets.yaml` is encrypted with these rules.
* **`encrypted_regex`**: only the values under `data` and `stringData` are encrypted
  (`ENC[AES256_GCM,...]`). `apiVersion`, `kind` and `metadata` stay readable, so the files
  can be reviewed in Git and schema-checked offline (`kubeconform`).
* **`age`**: the public recipient. `sops` encrypts for it automatically; only the matching
  private key (`key.txt`, never committed, ignored by `.gitignore`) can decrypt.

### Encrypted files

All nine files are encrypted for the one recipient above.

| File | Secrets |
|---|---|
| `gitops/apps/taskflow/taskflow-secrets.yaml` | `db-secret`, `backend-secret`, `redis-secret`, `cloudflare-secret` |
| `gitops/apps/taskflow/taskflow-jwt-secrets.yaml` | `taskflow-jwt-keys` (RSA JWT key material) |
| `gitops/infrastructure/controllers/proxmox-csi/proxmox-csi-secrets.yaml` | Proxmox CSI API credentials |
| `gitops/monitoring/platform/grafana-secrets.yaml` | Grafana admin and GitHub OAuth |
| `gitops/platform/abuseipdb/abuseipdb-secrets.yaml` | AbuseIPDB API key and Cloudflare API token |
| `gitops/platform/hubble-ui/hubble-ui-secrets.yaml` | Hubble UI `oauth2-proxy` GitHub OAuth |
| `gitops/platform/policy-reporter/policy-reporter-ui-oauth-secrets.yaml` | Policy Reporter UI `oauth2-proxy` GitHub OAuth |
| `gitops/platform/policy-reporter/policy-reporter-secrets.yaml` | Legacy, unused, but still listed in its `kustomization.yaml` |
| `gitops/platform/renovate/job/renovate-secrets.yaml` | Renovate GitHub credentials and host rules |

### Decryption in the cluster

Flux reads the private key from the Secret `flux-system/sops-age` (key `age.agekey`).
Every Flux Kustomization lives in `flux-system`, so this one Secret serves all of them.
The Kustomizations whose paths contain encrypted files declare `spec.decryption`:
`infra-controllers`, `taskflow-app`, `monitoring`, `abuseipdb`, `hubble-ui`,
`policy-reporter` and `renovate-job` (`renovate` declares it too, without an encrypted file
of its own). Excerpt of `gitops/clusters/taskflow/taskflow.yaml`:

```yaml
spec:
  path: ./gitops/apps/taskflow
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

The Secret is created once, by hand, during bring-up, before the `FluxInstance` is
applied: see [`gitops/FLUX_BOOTSTRAP.md` §3](../gitops/FLUX_BOOTSTRAP.md#3-seed-the-git-sops-and-ghcr-secrets).

### CI checks

`.github/workflows/validate-gitops.yaml` catches both halves of a broken pipeline before
merge:

* `ruby scripts/check-sops-secrets.rb`: every Secret with `data`/`stringData` under
  `gitops/` must be in a `*-secrets.yaml` file, and every such file must be encrypted for
  the `.sops.yaml` recipient with all values `ENC[...]`.
* `scripts/validate-gitops.sh` (through `scripts/flux-postbuild.rb`): fails a path that
  contains SOPS-encrypted documents when its Flux Kustomization has no `spec.decryption`.

---

## 2. Workstation setup

`mise install` installs the versions pinned in `mise.toml` (sops, age). Homebrew
(`brew install sops age`) and the
[release binaries](https://github.com/getsops/sops/releases) also work.

Point SOPS at the private key before decrypting or editing (add it to your shell profile
with an absolute path):

```bash
export SOPS_AGE_KEY_FILE=$PWD/key.txt
```

---

## 3. Everyday operations

```bash
# Edit an encrypted file in $EDITOR; SOPS re-encrypts on save
sops gitops/apps/taskflow/taskflow-secrets.yaml

# Print the decrypted file without changing it
sops -d gitops/apps/taskflow/taskflow-secrets.yaml

# Encrypt a new file in place (the name must end in -secrets.yaml)
sops -e -i gitops/apps/<app>/<name>-secrets.yaml
```

A new file starts as a plain Secret with `stringData`; add it to the directory's
`kustomization.yaml`, and make sure that path's Flux Kustomization has `spec.decryption`
(CI fails otherwise).

To see decrypted values in `git diff`, map the files to a SOPS diff driver (the repository
has no `.gitattributes`, so this is local):

```bash
git config diff.sops.textconv "sops -d"
echo '*-secrets.yaml diff=sops' >> .git/info/attributes
```

---

## 4. Key rotation and new environments

**Rotate the key** (old key still available):

```bash
age-keygen -o key.new.txt                 # prints "Public key: age1..."
# 1. put the new public key into .sops.yaml (creation_rules[0].age)
# 2. re-wrap every file for the new recipient, with the OLD key still in SOPS_AGE_KEY_FILE:
for f in $(git ls-files '*-secrets.yaml'); do sops updatekeys --yes "$f"; done
# 3. replace the in-cluster key, then reconcile
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=key.new.txt --dry-run=client -o yaml | kubectl apply -f -
```

`sops -r` alone is not enough: it rotates the data key for the file's *existing*
recipients.

**New environment without the old key:** the existing files cannot be decrypted. Put the
new public key into `.sops.yaml`, write your own values into each `*-secrets.yaml` as plain
`stringData`, and encrypt each again with `sops -e -i`.

**Where the private key lives:** in `key.txt` on the workstation and in
`flux-system/sops-age`. k3s secrets encryption at rest is not enabled
(`modules/proxmox/main.tf` sets no `secrets-encryption`), so the key is stored unencrypted
in the k3s datastore and in VM backups; keep an offline copy of `key.txt` in a password
manager.

---

## 5. Troubleshooting

### Local errors

| Error | Cause | Fix |
|---|---|---|
| `failed to get the data key` / no identity matched | SOPS cannot find the private key, or it is the wrong one | `export SOPS_AGE_KEY_FILE=...`; check that `age-keygen -y key.txt` prints the `recipient:` in the file's `sops:` block |
| `MAC mismatch` | The encrypted file was changed outside `sops` | Revert to the last committed version and edit only with `sops <file>` |

### A Flux Kustomization fails on an encrypted file

Flux decrypts only when **both** hold:

1. the Kustomization declares `spec.decryption` (in Git, under `gitops/clusters/taskflow/`;
   a `kubectl patch` is reverted by the next root sync), and
2. the `sops-age` Secret exists in the Kustomization's namespace (`flux-system`).

If either is missing, kustomize-controller refuses the encrypted Secret (current
releases report that it is SOPS encrypted and that decryption must be configured). Files
encrypted before `encrypted_regex` was added had every value encrypted and failed with
`dry-run failed: no matches for kind "ENC[AES256_GCM,...]"`. Either way it is a dry-run
failure: nothing was applied.

```bash
# Which Kustomization fails, and does it declare decryption?
flux get kustomizations -A
kubectl -n flux-system get kustomization <name> -o yaml | grep -A4 'decryption:'

# Does the key Secret exist? (-o name: never print the key)
kubectl -n flux-system get secret sops-age -o name

# Is the file encrypted for the key you have?
grep -A8 '^sops:' <file> | grep recipient
age-keygen -y key.txt

# After fixing: reconcile and check the Secret holds real values, not ENC[...]
flux reconcile kustomization <name> -n flux-system --with-source
kubectl -n <ns> get secret <secret> -o jsonpath='{.data}' | head -c 200
```
