#!/bin/bash
# Applies new Talos machine configs to all nodes in migration order.
# Prerequisites:
#   - Run migration-win-network.ps1 -Action Add first (adds 10.30.4.100/16 to your NIC)
#   - 1Password CLI (op) must be signed in: op signin
#   - talosconfig at repo root must be current

set -euo pipefail

cd "$(dirname "$0")/.."

TALOSCONFIG="$(pwd)/talosconfig"
TALOS_DIR="kubernetes/talos"

# Node name → old IP → new IP
NODES=("home-ops-02" "home-ops-01" "home-ops-00")
declare -A OLD_IP=( [home-ops-00]="10.30.4.1" [home-ops-01]="10.30.4.2" [home-ops-02]="10.30.4.3" )
declare -A NEW_IP=( [home-ops-00]="10.30.50.20" [home-ops-01]="10.30.50.21" [home-ops-02]="10.30.50.22" )
declare -A IS_CP=(  [home-ops-00]="true"        [home-ops-01]="true"        [home-ops-02]="true"        )

render_config() {
    local node="$1"
    local tmp_base; tmp_base="$(mktemp)"
    local tmp_patch; tmp_patch="$(mktemp)"
    local tmp_out; tmp_out="$(mktemp)"

    export IS_CONTROLPLANE="${IS_CP[$node]}"
    minijinja-cli --env "$TALOS_DIR/machineconfig.yaml.j2" | op inject > "$tmp_base"
    minijinja-cli --env "$TALOS_DIR/nodes/${node}.yaml.j2" | op inject > "$tmp_patch"
    talosctl machineconfig patch "$tmp_base" -p "@$tmp_patch" -o "$tmp_out"

    rm -f "$tmp_base" "$tmp_patch"
    echo "$tmp_out"
}

wait_for_talos() {
    local node="$1"
    local ip="$2"
    local max=300
    local elapsed=0

    echo "  Waiting for $node at $ip..."
    while ! talosctl --talosconfig "$TALOSCONFIG" -n "$ip" version &>/dev/null 2>&1; do
        [[ $elapsed -ge $max ]] && { echo "  ❌ Timeout after ${max}s"; return 1; }
        sleep 5; elapsed=$((elapsed + 5))
        printf "  ... %ds\r" "$elapsed"
    done
    echo "  ✅ $node reachable at $ip"
}

echo "=== Talos Network Migration ==="
echo ""
echo "Migration order (worker first, then control planes):"
for node in "${NODES[@]}"; do
    printf "  %-14s  %s → %s\n" "$node" "${OLD_IP[$node]}" "${NEW_IP[$node]}"
done
echo ""

# Pre-flight: verify old IPs are reachable
echo "Checking connectivity to nodes at old IPs..."
all_ok=true
for node in "${NODES[@]}"; do
    ip="${OLD_IP[$node]}"
    if talosctl --talosconfig "$TALOSCONFIG" -n "$ip" version &>/dev/null 2>&1; then
        echo "  ✅ $node ($ip)"
    else
        echo "  ❌ $node ($ip) — unreachable"
        all_ok=false
    fi
done

if [[ "$all_ok" != "true" ]]; then
    echo ""
    echo "Some nodes are unreachable. Fix WSL2 routing first:"
    echo "  GW=\$(ip route show default | awk '/default/ {print \$3}')"
    echo "  sudo ip route add 10.30.4.0/16 via \$GW"
    echo "  sudo iptables -t nat -A POSTROUTING -d 10.30.4.0/16 -j SNAT --to-source 10.30.4.100"
    exit 1
fi

echo ""
read -r -p "All nodes reachable. Start migration? (y/N) " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# Apply configs in order
for node in "${NODES[@]}"; do
    old="${OLD_IP[$node]}"
    new="${NEW_IP[$node]}"

    echo ""
    echo "=== $node: $old → $new ==="

    echo "  Rendering config..."
    config_file="$(render_config "$node")"

    echo "  Applying config to $old..."
    if talosctl --talosconfig "$TALOSCONFIG" -n "$old" apply-config --file "$config_file"; then
        echo "  ✅ Config applied — node is rebooting"
    else
        echo "  ❌ Failed to apply config to $node"
        rm -f "$config_file"
        exit 1
    fi
    rm -f "$config_file"

    sleep 10
    wait_for_talos "$node" "$new"

    # For control plane nodes give etcd time to rejoin before next node
    if [[ -n "${IS_CP[$node]}" ]]; then
        echo "  Waiting for etcd to stabilise..."
        sleep 20
        talosctl --talosconfig "$TALOSCONFIG" -n "$new" etcd members 2>/dev/null \
            && echo "  ✅ etcd healthy" || echo "  ⚠️  etcd check skipped — continuing"
    fi
done

echo ""
echo "=== All nodes migrated ==="
echo ""
echo "Next steps:"
echo "  1. Regenerate talosconfig:  bash scripts/generate-talosconfig.sh"
echo "  2. Fetch new kubeconfig:    talosctl kubeconfig -n 10.30.50.20 --force"
echo "  3. Verify nodes:            kubectl get nodes -o wide"
echo "  4. Push git changes:        git add -A && git commit && git push"
echo "     Flux will reconcile Cilium, external-dns, Rook-Ceph automatically."
