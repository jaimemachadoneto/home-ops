#!/bin/bash
set -euo pipefail

# Script to create 1Password items for Talos secrets
# Based on secrets.yaml and machineconfig.yaml.j2 requirements

SECRETS_FILE="secrets.yaml"

# Validation
if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "❌ Error: $SECRETS_FILE not found"
  echo "Run 'talosctl gen secrets > secrets.yaml' first"
  exit 1
fi

if ! command -v yq &> /dev/null; then
  echo "❌ Error: yq not found. Install it first."
  exit 1
fi

if ! command -v op &> /dev/null; then
  echo "❌ Error: 1Password CLI (op) not found. Install it first."
  exit 1
fi

echo "Creating 1Password secrets for Talos cluster..."

# Extract all secrets once
MACHINE_CA_CRT=$(yq '.certs.os.crt' "$SECRETS_FILE")
MACHINE_CA_KEY=$(yq '.certs.os.key' "$SECRETS_FILE")
MACHINE_TOKEN=$(yq '.secrets.bootstraptoken' "$SECRETS_FILE")
CLUSTER_CA_CRT=$(yq '.certs.k8s.crt' "$SECRETS_FILE")
CLUSTER_CA_KEY=$(yq '.certs.k8s.key' "$SECRETS_FILE")
CLUSTER_ID=$(yq '.cluster.id' "$SECRETS_FILE")
CLUSTER_SECRET=$(yq '.cluster.secret' "$SECRETS_FILE")
CLUSTER_TOKEN=$(yq '.trustdinfo.token' "$SECRETS_FILE")
CLUSTER_AGGREGATORCA_CRT=$(yq '.certs.k8saggregator.crt' "$SECRETS_FILE")
CLUSTER_AGGREGATORCA_KEY=$(yq '.certs.k8saggregator.key' "$SECRETS_FILE")
CLUSTER_ETCD_CA_CRT=$(yq '.certs.etcd.crt' "$SECRETS_FILE")
CLUSTER_ETCD_CA_KEY=$(yq '.certs.etcd.key' "$SECRETS_FILE")
CLUSTER_SECRETBOXENCRYPTIONSECRET=$(yq '.secrets.secretboxencryptionsecret' "$SECRETS_FILE")
CLUSTER_SERVICEACCOUNT_KEY=$(yq '.certs.k8sserviceaccount.key' "$SECRETS_FILE")

# Check if item exists
if op item get "talos" --vault "Home-Ops" &>/dev/null; then
  echo "Updating existing 1Password item..."
  op item edit "talos" --vault "Home-Ops" \
    MACHINE_CA_CRT[password]="$MACHINE_CA_CRT" \
    MACHINE_CA_KEY[password]="$MACHINE_CA_KEY" \
    MACHINE_TOKEN[password]="$MACHINE_TOKEN" \
    CLUSTER_CA_CRT[password]="$CLUSTER_CA_CRT" \
    CLUSTER_CA_KEY[password]="$CLUSTER_CA_KEY" \
    CLUSTER_ID[password]="$CLUSTER_ID" \
    CLUSTER_SECRET[password]="$CLUSTER_SECRET" \
    CLUSTER_TOKEN[password]="$CLUSTER_TOKEN" \
    CLUSTER_AGGREGATORCA_CRT[password]="$CLUSTER_AGGREGATORCA_CRT" \
    CLUSTER_AGGREGATORCA_KEY[password]="$CLUSTER_AGGREGATORCA_KEY" \
    CLUSTER_ETCD_CA_CRT[password]="$CLUSTER_ETCD_CA_CRT" \
    CLUSTER_ETCD_CA_KEY[password]="$CLUSTER_ETCD_CA_KEY" \
    CLUSTER_SECRETBOXENCRYPTIONSECRET[password]="$CLUSTER_SECRETBOXENCRYPTIONSECRET" \
    CLUSTER_SERVICEACCOUNT_KEY[password]="$CLUSTER_SERVICEACCOUNT_KEY"
else
  echo "Creating new 1Password item..."
  op item create --vault "Home-Ops" \
    --category "Secure Note" \
    --title "talos" \
    MACHINE_CA_CRT[password]="$MACHINE_CA_CRT" \
    MACHINE_CA_KEY[password]="$MACHINE_CA_KEY" \
    MACHINE_TOKEN[password]="$MACHINE_TOKEN" \
    CLUSTER_CA_CRT[password]="$CLUSTER_CA_CRT" \
    CLUSTER_CA_KEY[password]="$CLUSTER_CA_KEY" \
    CLUSTER_ID[password]="$CLUSTER_ID" \
    CLUSTER_SECRET[password]="$CLUSTER_SECRET" \
    CLUSTER_TOKEN[password]="$CLUSTER_TOKEN" \
    CLUSTER_AGGREGATORCA_CRT[password]="$CLUSTER_AGGREGATORCA_CRT" \
    CLUSTER_AGGREGATORCA_KEY[password]="$CLUSTER_AGGREGATORCA_KEY" \
    CLUSTER_ETCD_CA_CRT[password]="$CLUSTER_ETCD_CA_CRT" \
    CLUSTER_ETCD_CA_KEY[password]="$CLUSTER_ETCD_CA_KEY" \
    CLUSTER_SECRETBOXENCRYPTIONSECRET[password]="$CLUSTER_SECRETBOXENCRYPTIONSECRET" \
    CLUSTER_SERVICEACCOUNT_KEY[password]="$CLUSTER_SERVICEACCOUNT_KEY"
fi

echo "✅ All secrets have been created/updated in 1Password!"
echo ""
echo "Item location: Home-Ops/talos"
echo ""
echo "Next steps:"
echo "  1. Generate talosconfig: just template kubernetes/talos/talosconfig.yaml.j2 > talosconfig"
echo "  2. Reset nodes and apply config with new certificates"
