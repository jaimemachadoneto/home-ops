#!/bin/bash
set -euo pipefail

# Script to regenerate talosconfig with admin (os:admin) permissions
# Use this when you need to restore access to the cluster

cd "$(dirname "$0")/.."

echo "=== Regenerating Admin Talosconfig ==="
echo ""

if [ ! -f secrets.yaml ]; then
    echo "❌ secrets.yaml not found!"
    echo ""
    echo "Run this first:"
    echo "  ./scripts/create-1password-secrets.sh"
    exit 1
fi

echo "Generating talosconfig with os:admin role..."
if talosctl gen config --with-secrets secrets.yaml \
    --output-types talosconfig \
    --force \
    home-ops https://home-ops.internal:6443; then
    echo "✅ Admin talosconfig generated"
else
    echo "❌ Failed to generate talosconfig"
    exit 1
fi

echo ""
echo "Configuring endpoints and nodes..."
talosctl config endpoint 10.30.4.1 10.30.4.2 10.30.4.3
talosctl config node home-ops-00 home-ops-01 home-ops-02

echo ""
echo "✅ Talosconfig regenerated successfully!"
echo ""
talosctl config info
echo ""
echo "Testing access:"
talosctl -n 10.30.4.1 version --short 2>&1 | head -3
