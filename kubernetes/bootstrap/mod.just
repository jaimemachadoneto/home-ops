set positional-arguments := true
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

kubernetes_dir := justfile_dir() + '/kubernetes'
bootstrap_dir := kubernetes_dir + '/bootstrap'
talos_dir := kubernetes_dir + '/talos'
controller := `talosctl config info --output json | jq --raw-output '.endpoints[]' | shuf -n 1`
nodes := `talosctl config info -o yaml | yq -e '.nodes | join (" ")'`

[private]
default: kubernetes (kubeconfig "node") wait namespaces resources crds apps kubeconfig

[doc('Bootstrap cluster from maintenance mode (zero to cluster)')]
create-from-maintenance:
  #!/usr/bin/env bash
  set -euo pipefail

  just log info "Starting cluster bootstrap from maintenance mode" "stage" "create-from-maintenance"

  # STEP 1: Validate/create secrets in 1Password FIRST (before touching nodes)
  just log info "Validating secrets in 1Password" "stage" "create-from-maintenance"

  # Check if base secrets exist in 1Password
  if ! op item get talos --vault Home-Ops --fields label=MACHINE_CA_CRT &>/dev/null; then
    just log info "⚠️  No secrets found in 1Password" "stage" "create-from-maintenance"
    echo ""
    echo "This appears to be a fresh setup. Options:"
    echo "  1. Create NEW secrets and store in 1Password (recommended for new cluster)"
    echo "  2. Abort (if you need to manually import existing secrets)"
    echo ""
    read -p "Create new secrets in 1Password? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      just log fatal "Aborting. Import secrets to 1Password first" "stage" "create-from-maintenance"
    fi

    just log info "Generating new secrets" "stage" "create-from-maintenance"
    talosctl gen secrets -o secrets.yaml

    just log info "Storing secrets in 1Password" "stage" "create-from-maintenance"
    ./scripts/create-1password-secrets.sh

    just log info "Generating client certificate" "stage" "create-from-maintenance"
    ./scripts/generate-talosconfig-client-cert.sh
  elif ! op item get talos --vault Home-Ops --fields label=TALOSCONFIG_CLIENT_CRT &>/dev/null; then
    just log info "Client certificate not found in 1Password, generating..." "stage" "create-from-maintenance"
    if [ ! -f secrets.yaml ]; then
      just log info "Generating secrets.yaml from 1Password" "stage" "create-from-maintenance"
      ./scripts/generate-secrets-from-1password.sh
    fi
    ./scripts/generate-talosconfig-client-cert.sh
  fi

  just log info "✅ Secrets validated in 1Password" "stage" "create-from-maintenance"

  # STEP 2: Discover nodes from templates
  NODES_DIR="{{ talos_dir }}/nodes"
  if [ ! -d "$NODES_DIR" ]; then
    just log fatal "Nodes directory not found: $NODES_DIR" "stage" "create-from-maintenance"
  fi

  mapfile -t NODE_TEMPLATES < <(find "$NODES_DIR" -maxdepth 1 -name "*.yaml.j2" -type f | sort)

  if [ ${#NODE_TEMPLATES[@]} -eq 0 ]; then
    just log fatal "No node templates found in $NODES_DIR" "stage" "create-from-maintenance"
  fi

  NODES=()
  NODE_NAMES=()
  for template in "${NODE_TEMPLATES[@]}"; do
    node_name=$(basename "$template" .yaml.j2)
    NODE_NAMES+=("$node_name")
    # Extract IP from template
    node_ip=$(just template "$template" | yq -e '.machine.network.interfaces[] | select(.interface == "bond0") | .addresses[0]' | cut -d'/' -f1)
    NODES+=("$node_ip")
    just log info "Discovered node" "name" "$node_name" "ip" "$node_ip"
  done

  just log info "Found ${#NODES[@]} nodes to configure" "stage" "create-from-maintenance"

  # STEP 3: Generate admin talosconfig from 1Password (before applying to nodes)
  just log info "Generating admin talosconfig from 1Password" "stage" "create-from-maintenance"
  just template {{ talos_dir }}/talosconfig.yaml.j2 > {{ justfile_dir() }}/../../talosconfig

  # Configure endpoints and nodes
  talosctl config endpoint ${NODES[@]+"${NODES[@]}"}
  talosctl config node ${NODE_NAMES[@]+"${NODE_NAMES[@]}"}
  just log info "✅ Talosconfig ready" "stage" "create-from-maintenance"

  # STEP 4: Apply configuration to all nodes
  just log info "Applying Talos configuration to nodes" "stage" "create-from-maintenance"
  for i in "${!NODE_NAMES[@]}"; do
    node_name="${NODE_NAMES[$i]}"
    node_ip="${NODES[$i]}"

    just log info "Applying config" "node" "$node_name" "ip" "$node_ip"
    if ! just talos::apply-node "$node_name" --insecure --nodes "$node_ip" 2>&1; then
      just log fatal "Failed to apply config" "node" "$node_name" "stage" "create-from-maintenance"
    fi
  done

  # Wait for nodes to reboot and be ready
  just log info "Waiting for nodes to reboot (60 seconds)" "stage" "create-from-maintenance"
  sleep 60

  # Wait for nodes to be ready
  just log info "Waiting for nodes to be ready" "stage" "create-from-maintenance"
  for node_ip in "${NODES[@]}"; do
    until talosctl -n "$node_ip" version &>/dev/null; do
      just log info "Waiting for node to be ready" "ip" "$node_ip"
      sleep 5
    done
    just log info "Node ready" "ip" "$node_ip"
  done

  # Bootstrap etcd cluster on first control plane node
  just log info "Bootstrapping etcd cluster" "stage" "create-from-maintenance" "node" "${NODES[0]}"
  if ! talosctl bootstrap --nodes "${NODES[0]}" 2>&1; then
    just log fatal "Failed to bootstrap etcd" "stage" "create-from-maintenance"
  fi

  # Wait for Kubernetes API
  just log info "Waiting for Kubernetes API (30 seconds)" "stage" "create-from-maintenance"
  sleep 30

  # Fetch kubeconfig
  just log info "Fetching kubeconfig" "stage" "create-from-maintenance"
  if ! talosctl kubeconfig -n "${NODES[0]}" --force --merge=false {{ justfile_dir() }}/kubeconfig; then
    just log fatal "Failed to fetch kubeconfig" "stage" "create-from-maintenance"
  fi

  just log info "Cluster bootstrap complete" "stage" "create-from-maintenance"
  just log info "Next: Run 'just k8s-bootstrap' to install CNI and applications"

[doc('Install Talos')]
talos:
  #!/usr/bin/env bash
  set -euo pipefail
  just log info "Running stage..." "stage" "talos"

  NODES=({{ nodes }})
  for n in "${NODES[@]}"; do
    echo "Checking node: $n"
    if ! output=$(just talos::apply-node "$n" --insecure 2>&1); then
      if [[ "$output" == *"certificate required"* ]] || [[ "$output" == *"certificate"* ]]; then
        just log info "Talos already configured, skipping" "stage" "talos" "node" "$n"
        continue
      fi
      echo "ERROR: Failed to apply Talos configuration to $n"
      echo "$output"
      just log fatal "Failed to apply Talos configuration" "stage" "talos" "node" "$n"
      exit 1
    fi
    just log info "Applied Talos config" "stage" "talos" "node" "$n"
  done

[doc('Install Kubernetes')]
kubernetes:
  just log info "Running stage..." "stage" "$0"
  until op=$(talosctl -n "{{ controller }}" bootstrap 2>&1 || true) && [[ "$op" == *"AlreadyExists"* ]]; do \
    just log info "Kubernetes bootstrap in progress. Retrying in 5 seconds..." "stage" "$0"; \
    sleep 5; \
  done

[doc('Fetch kubeconfig')]
kubeconfig lb="cilium":
  just log info "Running stage..." "stage" "$0"
  if ! talosctl kubeconfig -n "{{ controller }}" -f --force-context-name home-ops {{ justfile_dir() }}/kubeconfig; then \
    just log fatal "Failed to fetch kubeconfig" "stage" "$0"; \
  fi
  if [[ "{{ lb }}" != "cilium" ]]; then \
    if ! KUBECONFIG={{ justfile_dir() }}/kubeconfig kubectl config set-cluster home-ops --server "https://{{ controller }}:6443"; then \
      just log fatal "Failed to set kubectl cluster server address" "stage" "$0"; \
    fi; \
  fi

[doc('Wait for nodes to be not-ready')]
wait:
  just log info "Running stage..." "stage" "$0"
  export KUBECONFIG={{ justfile_dir() }}/kubeconfig; \
  if ! kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then \
    until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do \
      just log info "Nodes not available, waiting for nodes to be available. Retrying in 5 seconds..." "stage" "$0"; \
      sleep 5; \
    done \
  fi

[doc('Apply Kubernetes namespaces')]
namespaces:
  just log info "Running stage..." "stage" "$0"
  export KUBECONFIG={{ justfile_dir() }}/kubeconfig; \
  find "{{ kubernetes_dir }}/apps" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | while IFS= read -r ns; do \
    if ! kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply --server-side -f -; then \
      just log fatal "Failed to apply namespace" "stage" "create_namespaces" "namespace" "$ns"; \
    fi; \
  done

[doc('Apply Kubernetes resources')]
resources:
  just log info "Running stage..." "stage" "$0"
  export KUBECONFIG={{ justfile_dir() }}/kubeconfig; \
  if ! just template "{{ bootstrap_dir }}/resources.yaml.j2" | kubectl apply --server-side -f -; then \
    just log fatal "Failed to apply resources" "stage" "$0"; \
  fi;

[doc('Apply Helmfile CRDs')]
crds:
  just log info "Running stage..." "stage" "$0"
  export KUBECONFIG={{ justfile_dir() }}/kubeconfig; \
  if ! helmfile -f "{{ bootstrap_dir }}/helmfile.d/00-crds.yaml" template -q | kubectl apply --server-side -f -; then \
    just log fatal "Failed to apply crds" "stage" "$0"; \
  fi;

[doc('Apply Helmfile Apps')]
apps:
  just log info "Running stage..." "stage" "$0"
  export KUBECONFIG={{ justfile_dir() }}/kubeconfig; \
  if ! helmfile -f "{{ bootstrap_dir }}/helmfile.d/01-apps.yaml" sync --hide-notes; then \
    just log fatal "Failed to sync helmfile" "stage" "$0"; \
  fi

[doc('Reset all nodes back to maintenance mode (DESTRUCTIVE)')]
destroy-cluster:
  #!/usr/bin/env bash
  set -euo pipefail

  # Get nodes from talosconfig
  TALOSCONFIG_PATH="{{ justfile_dir() }}/talosconfig"
  if [ ! -f "$TALOSCONFIG_PATH" ]; then
    echo "❌ talosconfig not found at $TALOSCONFIG_PATH"
    echo "Run: just setup-dev"
    exit 1
  fi

  NODES=($(talosctl config info -o yaml | yq -e '.nodes[]'))

  if [ ${#NODES[@]} -eq 0 ]; then
    echo "❌ No nodes found in talosconfig"
    exit 1
  fi

  echo "=== DESTROY CLUSTER ==="
  echo ""
  echo "⚠️  WARNING: This will:"
  echo "  • Wipe all data on ${#NODES[@]} node(s): ${NODES[@]}"
  echo "  • Reset nodes to maintenance mode"
  echo "  • Delete all Kubernetes resources"
  echo ""
  read -p "Are you ABSOLUTELY sure? Type 'destroy' to confirm: " confirm
  if [[ "$confirm" != "destroy" ]]; then
    echo "Aborting."
    exit 1
  fi

  echo ""
  echo "=== Resetting nodes ==="
  for node in "${NODES[@]}"; do
    echo "Resetting $node..."
    if talosctl -n "$node" reset \
      --system-labels-to-wipe STATE \
      --system-labels-to-wipe EPHEMERAL \
      --graceful=false \
      --reboot 2>/dev/null; then
      echo "✅ $node reset"
    else
      echo "⚠️  $node reset failed or already in maintenance mode"
    fi
  done

  echo ""
  echo "✅ All nodes reset to maintenance mode"
  echo ""
  echo "Nodes will reboot into maintenance mode."
  echo "You can now run 'just create-cluster' to rebuild."
