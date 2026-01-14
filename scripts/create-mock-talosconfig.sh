#!/bin/bash
set -e

# Script to create a mock talosconfig for testing purposes

cat > talosconfig <<EOF
context: mock-context
contexts:
  mock-context:
    endpoints:
      - 192.168.1.10
      - 192.168.1.11
      - 192.168.1.12
endpoints:
  - 192.168.1.10
  - 192.168.1.11
  - 192.168.1.12
EOF

echo "Mock talosconfig created successfully."
