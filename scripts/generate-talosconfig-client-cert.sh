#!/bin/bash
set -euo pipefail

# Generate talosconfig client certificate and store in 1Password
# Run this once, then your talosconfig template will work

cd "$(dirname "$0")/.."

echo "=== Generating Talosconfig Client Certificate ==="
echo ""

if [ ! -f secrets.yaml ]; then
    echo "❌ secrets.yaml not found!"
    exit 1
fi

# Generate talosconfig in temp location
TEMP_CONFIG=$(mktemp)
talosctl gen config --with-secrets secrets.yaml \
    --output-types talosconfig \
    --force \
    home-ops https://home-ops.internal:6443 \
    > /dev/null 2>&1

mv talosconfig "$TEMP_CONFIG"

echo "Extracting client certificate and key..."
CLIENT_CRT=$(yq '.contexts.home-ops.crt' "$TEMP_CONFIG")
CLIENT_KEY=$(yq '.contexts.home-ops.key' "$TEMP_CONFIG")

echo "Storing in 1Password..."
if op item get talos --vault Home-Ops &>/dev/null; then
    op item edit talos --vault Home-Ops \
        "TALOSCONFIG_CLIENT_CRT[password]=$CLIENT_CRT" \
        "TALOSCONFIG_CLIENT_KEY[password]=$CLIENT_KEY"
    echo "✅ Updated existing 1Password item"
else
    echo "❌ 1Password item 'talos' not found"
    exit 1
fi

# Cleanup
rm -f "$TEMP_CONFIG"

echo ""
echo "✅ Client certificate stored in 1Password!"
echo ""
echo "Note: This certificate expires in 1 year ($(date -d '+1 year' '+%Y-%m-%d'))"
echo "You'll need to re-run this script annually."
echo ""
echo "Now you can use the template:"
echo "  minijinja-cli --env kubernetes/talos/talosconfig.yaml.j2 | op inject > talosconfig"
