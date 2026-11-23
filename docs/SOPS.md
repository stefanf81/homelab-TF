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
  private key (never committed, kept outside the repository, see §2) can decrypt.

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

Keep the private key outside the repository, so that a copy, backup or sync of the working
tree never contains it, and point SOPS at it (add the export to your shell profile):

```bash
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
```

A key that still lives in the repository root as `key.txt` (the earlier layout) keeps
working and is ignored by Git; move it once:

```bash
mkdir -p "$(dirname "$SOPS_AGE_KEY_FILE")" && chmod 700 "$(dirname "$SOPS_AGE_KEY_FILE")"
mv key.txt "$SOPS_AGE_KEY_FILE" && chmod 600 "$SOPS_AGE_KEY_FILE"
```

A new environment generates its key in the same place: `age-keygen -o "$SOPS_AGE_KEY_FILE"`.

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

**Rotate the key** (old key still available). The key file may hold several keys, one
per line; SOPS and Flux try each of them. That makes the order safe: the cluster can
decrypt both the old and the new files while the change travels through Git.

```bash
# 1. append a new key to the key file (never into the repository); prints "Public key: age1..."
age-keygen >> "$SOPS_AGE_KEY_FILE"

# 2. give Flux both keys before any file changes
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey="$SOPS_AGE_KEY_FILE" --dry-run=client -o yaml | kubectl apply -f -

# 3. put the new public key into .sops.yaml (creation_rules[0].age), then re-wrap every
#    file for it and give each file a new data key
for f in $(git ls-files '*-secrets.yaml'); do sops updatekeys --yes "$f" && sops rotate -i "$f"; done
ruby scripts/check-sops-secrets.rb          # every file is encrypted for the new recipient

# 4. commit, push, and wait until every Kustomization is Ready again
flux get kustomizations -A

# 5. delete the old key (its three lines) from the key file, then repeat step 2 so the
#    cluster holds only the new key; update the offline copy in the password manager
age-keygen -y "$SOPS_AGE_KEY_FILE"          # prints exactly one public key: the new one
```

Both commands in step 3 are needed. `sops updatekeys` changes who can unwrap the file's
data key but keeps that data key; `sops rotate` creates a new data key but keeps the
recipients. Without `rotate`, someone who held the old key could still decrypt later
versions of a file with the data key they already extracted.

Rotation does not protect what is already in the Git history: every earlier commit stays
readable with the old key. After a suspected leak, change the secret values themselves as
well (tokens, passwords, the JWT key).

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
| `failed to get the data key` / no identity matched | SOPS cannot find the private key, or it is the wrong one | `export SOPS_AGE_KEY_FILE=...`; check that `age-keygen -y "$SOPS_AGE_KEY_FILE"` prints the `recipient:` in the file's `sops:` block |
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
age-keygen -y "$SOPS_AGE_KEY_FILE"

# After fixing: reconcile and check the Secret holds real values, not ENC[...]
flux reconcile kustomization <name> -n flux-system --with-source
kubectl -n <ns> get secret <secret> -o jsonpath='{.data}' | head -c 200
```
