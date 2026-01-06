#!/usr/bin/env -S just --justfile

set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

mod k8s-bootstrap "kubernetes/bootstrap"
mod k8s "kubernetes"
mod talos "kubernetes/talos"

[private]
default:
    just -l

[private]
log lvl msg *args:
  gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template file *args:
  minijinja-cli "{{ file }}" {{ args }} | op inject

# === Cluster Lifecycle Management ===

[doc('Bootstrap cluster from maintenance mode (assumes all nodes booted from installer)')]
create-cluster:
  #!/usr/bin/env bash
  set -euo pipefail

  echo "=== Creating Talos Cluster ==="
  echo ""
  echo "This will:"
  echo "  1. Apply Talos config to all nodes in maintenance mode"
  echo "  2. Bootstrap etcd and Kubernetes"
  echo "  3. Install CNI and all applications"
  echo ""
  echo "Prerequisites:"
  echo "  • All nodes must be in maintenance/installer mode"
  echo "  • Secrets must be in 1Password (Home-Ops/talos)"
  echo "  • 1Password CLI authenticated (eval \$(op signin))"
  echo ""
  read -p "Continue? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborting."
    exit 1
  fi

  # Phase 1: Bootstrap from maintenance mode
  echo ""
  just log info "Phase 1: Bootstrap from maintenance mode"
  just k8s-bootstrap create-from-maintenance

  # Phase 2: Install CNI and applications
  echo ""
  just log info "Phase 2: Install CNI and applications"
  just k8s-bootstrap

  echo ""
  just log info "✅ Cluster fully operational!"
  echo ""
  echo "Cluster status:"
  export KUBECONFIG=$(pwd)/kubeconfig
  kubectl get nodes
  echo ""
  echo "Access cluster:"
  echo "  export KUBECONFIG=$(pwd)/kubeconfig"
  echo "  kubectl get pods -A"

[doc('Reset all nodes back to maintenance mode (DESTRUCTIVE)')]
destroy-cluster:
  just k8s-bootstrap destroy-cluster

[doc('Setup development machine for cluster access (run after fresh clone)')]
setup-dev:
  #!/usr/bin/env bash
  set -euo pipefail

  echo "=== Setting Up Development Machine ==="
  echo ""

  # Check 1Password authentication
  echo "Checking 1Password authentication..."
  if ! op account list &>/dev/null; then
    echo "❌ Not authenticated to 1Password"
    echo ""
    echo "Run: eval \$(op signin)"
    exit 1
  fi
  echo "✅ 1Password authenticated"

  # Generate secrets.yaml
  echo ""
  echo "=== Generating secrets.yaml from 1Password ==="
  if [ -f secrets.yaml ]; then
    echo "⚠️  secrets.yaml already exists"
    read -p "Regenerate? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Skipping secrets.yaml generation"
    else
      ./scripts/generate-secrets-from-1password.sh
    fi
  else
    ./scripts/generate-secrets-from-1password.sh
  fi

  # Generate talosconfig
  echo ""
  echo "=== Generating talosconfig ==="
  if [ -f talosconfig ]; then
    echo "⚠️  talosconfig already exists"
    read -p "Regenerate? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Skipping talosconfig generation"
    else
      just template kubernetes/talos/talosconfig.yaml.j2 > talosconfig
    fi
  else
    just template kubernetes/talos/talosconfig.yaml.j2 > talosconfig
  fi

  # Verify talosconfig
  echo ""
  echo "=== Verifying talosconfig ==="
  if talosctl config info | grep -q "os:admin"; then
    echo "✅ Talosconfig has admin role"
  else
    echo "❌ Talosconfig missing admin role"
    echo ""
    echo "Run: ./scripts/generate-talosconfig-client-cert.sh"
    exit 1
  fi

  # Try to get first node from talosconfig (may not exist if cluster not created yet)
  FIRST_NODE=$(talosctl config info -o yaml | yq -e '.nodes[0]' 2>/dev/null || echo "")

  if [ -z "$FIRST_NODE" ]; then
    echo ""
    echo "⚠️  No nodes configured in talosconfig"
    echo "   This is normal if cluster doesn't exist yet."
    echo "   Run 'just create-cluster' to create the cluster."
  else
    # Test cluster access
    echo ""
    echo "=== Testing cluster access ==="
    if talosctl -n "$FIRST_NODE" version --short &>/dev/null; then
      echo "✅ Can access Talos nodes"
      talosctl -n "$FIRST_NODE" version --short 2>&1 | head -3 || true
    else
      echo "⚠️  Cannot access Talos nodes (cluster may be down)"
    fi

    # Fetch kubeconfig
    echo ""
    echo "=== Fetching kubeconfig ==="
    if talosctl -n "$FIRST_NODE" version --short &>/dev/null; then
      if [ -f kubeconfig ]; then
        echo "⚠️  kubeconfig already exists"
        read -p "Regenerate? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
          talosctl kubeconfig -n "$FIRST_NODE" --force --merge=false kubeconfig
          echo "✅ Kubeconfig fetched"
        fi
      else
        talosctl kubeconfig -n "$FIRST_NODE" --force --merge=false kubeconfig
        echo "✅ Kubeconfig fetched"
      fi
    else
      echo "⚠️  Cluster not accessible - skipping kubeconfig fetch"
    fi

    # Test Kubernetes access
    if [ -f kubeconfig ]; then
      echo ""
      echo "=== Testing Kubernetes access ==="
      export KUBECONFIG=$(pwd)/kubeconfig
      if kubectl get nodes &>/dev/null; then
        echo "✅ Can access Kubernetes"
        kubectl get nodes
      else
        echo "⚠️  Cannot access Kubernetes API"
      fi
    fi
  fi

  echo ""
  echo "✅ Development machine setup complete!"
  echo ""
  echo "Files created:"
  echo "  • secrets.yaml (from 1Password)"
  echo "  • talosconfig (admin access)"
  if [ -f kubeconfig ]; then
    echo "  • kubeconfig (Kubernetes access)"
  fi
  echo ""
  echo "Usage:"
  echo "  • Talos: talosctl -n $FIRST_NODE version"
  echo "  • Kubernetes: export KUBECONFIG=$(pwd)/kubeconfig && kubectl get nodes"
