#!/bin/bash
set -e

# Script to generate secrets.yaml from 1Password
# Reads from Home-ops/talos vault and creates secrets.yaml

echo "Fetching secrets from 1Password..."

# Check if op is authenticated
# if ! op whoami &>/dev/null; then
#     echo "Error: Not authenticated to 1Password. Run 'eval \$(op signin)' first."
#     exit 1
# fi

# Fetch all fields from the 1Password item
echo "Retrieving secrets from Home-ops/talos..."

MACHINE_CA_CRT=$(op read "op://Home-ops/talos/MACHINE_CA_CRT")
MACHINE_CA_KEY=$(op read "op://Home-ops/talos/MACHINE_CA_KEY")
MACHINE_TOKEN=$(op read "op://Home-ops/talos/MACHINE_TOKEN")
CLUSTER_CA_CRT=$(op read "op://Home-ops/talos/CLUSTER_CA_CRT")
CLUSTER_CA_KEY=$(op read "op://Home-ops/talos/CLUSTER_CA_KEY")
CLUSTER_ID=$(op read "op://Home-ops/talos/CLUSTER_ID")
CLUSTER_SECRET=$(op read "op://Home-ops/talos/CLUSTER_SECRET")
CLUSTER_TOKEN=$(op read "op://Home-ops/talos/CLUSTER_TOKEN")
CLUSTER_AGGREGATORCA_CRT=$(op read "op://Home-ops/talos/CLUSTER_AGGREGATORCA_CRT")
CLUSTER_AGGREGATORCA_KEY=$(op read "op://Home-ops/talos/CLUSTER_AGGREGATORCA_KEY")
CLUSTER_ETCD_CA_CRT=$(op read "op://Home-ops/talos/CLUSTER_ETCD_CA_CRT")
CLUSTER_ETCD_CA_KEY=$(op read "op://Home-ops/talos/CLUSTER_ETCD_CA_KEY")
CLUSTER_SECRETBOXENCRYPTIONSECRET=$(op read "op://Home-ops/talos/CLUSTER_SECRETBOXENCRYPTIONSECRET")
CLUSTER_SERVICEACCOUNT_KEY=$(op read "op://Home-ops/talos/CLUSTER_SERVICEACCOUNT_KEY")

# Generate secrets.yaml
cat > secrets.yaml <<EOF
cluster:
  id: ${CLUSTER_ID}
  secret: ${CLUSTER_SECRET}
secrets:
  bootstraptoken: ${MACHINE_TOKEN}
  secretboxencryptionsecret: ${CLUSTER_SECRETBOXENCRYPTIONSECRET}
trustdinfo:
  token: ${CLUSTER_TOKEN}
certs:
  etcd:
    crt: ${CLUSTER_ETCD_CA_CRT}
    key: ${CLUSTER_ETCD_CA_KEY}
  k8s:
    crt: ${CLUSTER_CA_CRT}
    key: ${CLUSTER_CA_KEY}
  k8saggregator:
    crt: ${CLUSTER_AGGREGATORCA_CRT}
    key: ${CLUSTER_AGGREGATORCA_KEY}
  k8sserviceaccount:
    key: ${CLUSTER_SERVICEACCOUNT_KEY}
  os:
    crt: ${MACHINE_CA_CRT}
    key: ${MACHINE_CA_KEY}
EOF

echo "✅ secrets.yaml has been generated successfully!"
echo ""
echo "⚠️  Warning: This file contains sensitive data. Make sure it's in .gitignore!"
