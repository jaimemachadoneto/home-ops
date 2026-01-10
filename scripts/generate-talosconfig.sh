#!/bin/bash
set -e

# Script to generate talosconfig from 1Password
# Fetches CA, client cert, and key from Home-ops/talos vault
# Uses fixed endpoints from talos/nodes

echo "Fetching talosconfig data from 1Password..."

# Fetch certificates from 1Password
CA_CRT=$(op read "op://Home-ops/talos/MACHINE_CA_CRT")
CLIENT_CRT=$(op read "op://Home-ops/talos/TALOSCONFIG_CLIENT_CRT")
CLIENT_KEY=$(op read "op://Home-ops/talos/TALOSCONFIG_CLIENT_KEY")

# Generate talosconfig
cat > talosconfig <<EOF
context: home-ops
contexts:
  home-ops:
    endpoints:
      - 10.30.4.1
      - 10.30.4.2
      - 10.30.4.3
    nodes:
      - home-ops-00
      - home-ops-01
      - home-ops-02
    ca: |
$(echo "$CA_CRT" | sed 's/^/      /')
    crt: |
$(echo "$CLIENT_CRT" | sed 's/^/      /')
    key: |
$(echo "$CLIENT_KEY" | sed 's/^/      /')
EOF

echo "talosconfig created successfully."
