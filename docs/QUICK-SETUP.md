# Quick Reference: Cluster Management

## Fresh Clone Setup (New Computer)

```bash
# 1. Authenticate to 1Password
eval $(op signin)

# 2. Setup your development machine
just setup-dev
```

This will:

- Generate `secrets.yaml` from 1Password
- Generate `talosconfig` with admin access
- Fetch `kubeconfig` from cluster (if running)
- Test connectivity

## Create New Cluster

```bash
# Boot all nodes from Talos installer, then:
just create-cluster
```

This will:

- Apply configuration to all nodes
- Generate admin talosconfig
- Bootstrap etcd cluster
- Fetch kubeconfig
- Verify cluster is ready

## Destroy Cluster

```bash
# WARNING: Destructive operation!
just destroy-cluster
```

This will:

- Reset all nodes to maintenance mode
- Wipe all data
- Reboot nodes into installer

## Files NOT in Git (.gitignore)

- `secrets.yaml` - Complete secrets (generated from 1Password)
- `talosconfig` - Cluster access (generated from template)
- `kubeconfig` - Kubernetes access (fetched from cluster)

## Files IN Git

- `kubernetes/talos/*.j2` - All templates
- `scripts/*` - All helper scripts
- Templates only contain 1Password references: `op://Home-Ops/talos/...`

## Manual Operations

### Regenerate talosconfig

```bash
just template kubernetes/talos/talosconfig.yaml.j2 > talosconfig
```

### Regenerate secrets.yaml

```bash
./scripts/generate-secrets-from-1password.sh
```

### Refresh client certificate (annual)

```bash
./scripts/generate-talosconfig-client-cert.sh
just template kubernetes/talos/talosconfig.yaml.j2 > talosconfig
```

### Apply config to single node

```bash
just talos apply-node home-ops-00
```

### Access cluster

```bash
# Talos
talosctl -n 10.30.4.1 version

# Kubernetes
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```
