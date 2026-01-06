#!/bin/bash
set -euo pipefail

# Script to apply fresh Talos configuration to nodes in installer mode
# Run this after booting nodes from Talos installer media

NODES=("10.30.4.1" "10.30.4.2" "10.30.4.3")
NODE_NAMES=("home-ops-00" "home-ops-01" "home-ops-02")

cd "$(dirname "$0")/.."

echo "=== Applying Fresh Talos Configuration ==="
echo ""
echo "Prerequisites:"
echo "  ✓ Nodes must be booted from Talos installer (USB/ISO/PXE)"
echo "  ✓ Nodes will accept --insecure in installer mode"
echo "  ✓ Secrets already in 1Password (Home-Ops/talos)"
echo ""

read -p "Are all nodes in installer mode? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborting. Boot nodes from installer first."
    exit 1
fi

# Apply config to each node
for i in "${!NODES[@]}"; do
    NODE_IP="${NODES[$i]}"
    NODE_NAME="${NODE_NAMES[$i]}"

    echo ""
    echo "=== Applying config to $NODE_NAME ($NODE_IP) ==="

    # Generate config from template
    CONFIG_FILE="/tmp/talos-${NODE_NAME}.yaml"
    export IS_CONTROLPLANE=true
    minijinja-cli --env kubernetes/talos/machineconfig.yaml.j2 | op inject > "$CONFIG_FILE.base"
    minijinja-cli --env "kubernetes/talos/nodes/${NODE_NAME}.yaml.j2" | op inject > "$CONFIG_FILE.patch"

    # Patch and apply
    talosctl machineconfig patch "$CONFIG_FILE.base" -p @"$CONFIG_FILE.patch" -o "$CONFIG_FILE"

    echo "Applying configuration..."
    if talosctl apply-config --insecure --nodes "$NODE_IP" --file "$CONFIG_FILE"; then
        echo "✅ Config applied to $NODE_NAME"
    else
        echo "❌ Failed to apply config to $NODE_NAME"
        exit 1
    fi

    # Cleanup
    rm -f "$CONFIG_FILE" "$CONFIG_FILE.base" "$CONFIG_FILE.patch"
done

echo ""
echo "=== Waiting for nodes to reboot and be ready ==="
echo "This may take 2-3 minutes..."
sleep 60

# Wait for nodes to be responsive
for NODE_IP in "${NODES[@]}"; do
    echo "Waiting for $NODE_IP..."
    until talosctl -n "$NODE_IP" version &>/dev/null; do
        echo "  Still waiting..."
        sleep 5
    done
    echo "  ✅ Ready"
done

echo ""
echo "=== Generating admin talosconfig ==="
echo "Creating talosconfig with os:admin role..."
if talosctl gen config --with-secrets secrets.yaml \
    --output-types talosconfig \
    --force \
    home-ops https://home-ops.internal:6443; then
    echo "✅ Admin talosconfig generated"
else
    echo "❌ Failed to generate talosconfig"
    exit 1
fi

# Configure endpoints and nodes
talosctl config endpoint "${NODES[@]}"
talosctl config node "${NODE_NAMES[@]}"
echo "✅ Endpoints and nodes configured"

echo ""
echo "=== Bootstrap cluster ==="
echo "Bootstrapping etcd on first node..."
if talosctl bootstrap --nodes "${NODES[0]}"; then
    echo "✅ Cluster bootstrapped"
else
    echo "❌ Bootstrap failed"
    exit 1
fi

echo ""
echo "=== Checking cluster formation ==="
sleep 10
talosctl -n "${NODES[0]}" get members

echo ""
echo "✅ Bootstrap complete!"
echo ""
echo "Next steps:"
echo "  1. Fetch kubeconfig: talosctl kubeconfig -n ${NODES[0]} -f"
echo "  2. Check nodes: kubectl get nodes"
echo "  3. Continue with Kubernetes apps installation"
