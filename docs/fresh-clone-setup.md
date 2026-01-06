# Fresh Clone Setup

This guide explains how to set up this repository on a new computer. All secrets are stored in 1Password and are not committed to git.

## Prerequisites

1. **1Password CLI** installed and authenticated
   ```bash
   # Install (if needed)
   brew install 1password-cli  # macOS
   # or follow: https://developer.1password.com/docs/cli/get-started/

   # Authenticate
   eval $(op signin)
   ```

2. **Required tools**:
   - `talosctl` - Talos CLI
   - `kubectl` - Kubernetes CLI
   - `minijinja-cli` - Template rendering
   - `yq` - YAML processor
   - `just` - Command runner

## Setup Steps

### 1. Clone Repository
```bash
git clone <your-repo-url>
cd home-ops
```

### 2. Generate Local Secrets Files

The repository uses 1Password for secret storage, but some local files are needed:

```bash
# If this is a FRESH setup (no cluster exists yet):
# Generate new secrets and store in 1Password
talosctl gen secrets -o secrets.yaml
./scripts/create-1password-secrets.sh

# If cluster ALREADY exists (secrets are in 1Password):
# Create secrets.yaml from 1Password
./scripts/generate-secrets-from-1password.sh
```

### 3. Generate Talosconfig

```bash
# This generates talosconfig with admin (os:admin) permissions
minijinja-cli --env kubernetes/talos/talosconfig.yaml.j2 | op inject > talosconfig

# Verify it works
talosctl config info
# Should show: Roles: os:admin
```

### 4. Generate Kubeconfig (if cluster exists)

```bash
# Fetch kubeconfig from cluster
talosctl kubeconfig -n 10.30.4.1 --force --merge=false kubeconfig

# Test access
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

## What's Stored Where

### In 1Password (vault: Home-Ops, item: talos)

**Machine Configuration Secrets** (from `talosctl gen secrets`):
- `MACHINE_CA_CRT` - Machine CA certificate (10 year)
- `MACHINE_CA_KEY` - Machine CA private key
- `MACHINE_TOKEN` - Machine bootstrap token
- `CLUSTER_CA_CRT` - Kubernetes CA certificate
- `CLUSTER_CA_KEY` - Kubernetes CA private key
- `CLUSTER_ID` - Cluster unique identifier
- `CLUSTER_SECRET` - Cluster secret
- `CLUSTER_TOKEN` - Cluster bootstrap token
- `CLUSTER_AGGREGATORCA_CRT` - API aggregation CA cert
- `CLUSTER_AGGREGATORCA_KEY` - API aggregation CA key
- `CLUSTER_ETCD_CA_CRT` - etcd CA certificate
- `CLUSTER_ETCD_CA_KEY` - etcd CA private key
- `CLUSTER_SECRETBOXENCRYPTIONSECRET` - Encryption secret
- `CLUSTER_SERVICEACCOUNT_KEY` - Service account signing key

**Talosconfig Client Certificates** (1 year expiration):
- `TALOSCONFIG_CLIENT_CRT` - Client certificate for admin access
- `TALOSCONFIG_CLIENT_KEY` - Client private key

### Local Files (in .gitignore)

These are generated from 1Password and NOT committed:
- `secrets.yaml` - Complete secrets file for `talosctl` commands
- `talosconfig` - Talos cluster access credentials
- `kubeconfig` - Kubernetes cluster access credentials

### In Git

These ARE committed:
- `kubernetes/talos/machineconfig.yaml.j2` - Machine config template
- `kubernetes/talos/nodes/*.yaml.j2` - Node-specific configs
- `kubernetes/talos/talosconfig.yaml.j2` - Talosconfig template
- `scripts/` - All helper scripts

## Common Operations

### Accessing an Existing Cluster

```bash
# 1. Ensure 1Password is authenticated
eval $(op signin)

# 2. Generate talosconfig
minijinja-cli --env kubernetes/talos/talosconfig.yaml.j2 | op inject > talosconfig

# 3. Generate kubeconfig
talosctl kubeconfig -n 10.30.4.1 --force --merge=false kubeconfig

# 4. Access cluster
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

### Updating Node Configuration

```bash
# Ensure you have talosconfig and secrets.yaml
just talos apply-node home-ops-00
```

### Regenerating Client Certificate (annually)

The talosconfig client certificate expires after 1 year. Regenerate it:

```bash
./scripts/generate-talosconfig-client-cert.sh
```

This updates 1Password with a fresh client certificate. Then regenerate talosconfig:

```bash
minijinja-cli --env kubernetes/talos/talosconfig.yaml.j2 | op inject > talosconfig
```

## Troubleshooting

### "not authorized" errors

Your talosconfig client certificate may have expired or is missing. Run:

```bash
./scripts/generate-talosconfig-client-cert.sh
minijinja-cli --env kubernetes/talos/talosconfig.yaml.j2 | op inject > talosconfig
```

### Missing secrets.yaml

Generate it from 1Password:

```bash
./scripts/generate-secrets-from-1password.sh
```

### 1Password authentication failed

Sign in again:

```bash
eval $(op signin)
```

## Security Notes

- **Never commit** `secrets.yaml`, `talosconfig`, or `kubeconfig`
- All secrets are encrypted in 1Password
- Templates contain only 1Password references (`op://Home-Ops/talos/...`)
- Client certificates expire after 1 year (renew annually)
- Machine CA certificates expire after 10 years
