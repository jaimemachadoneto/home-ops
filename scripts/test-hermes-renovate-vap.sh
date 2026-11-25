#!/usr/bin/env bash
# Test what the account hermes-dev-renovate can change: its role and the
# admission policy hermes-dev-renovate (kubernetes/apps/hermes-sandbox/
# sandbox-tenant/app). It works like test-flux-ops-mcp-vap.sh: a temporary
# kube-apiserver and etcd on localhost, the CRDs copied from the home cluster
# (read only), and each request sent as the account with `--dry-run=server`.
# Run it by hand or with `just test-hermes-renovate-vap`. CI does not run it.
# Needs: etcd, kube-apiserver, kubeadm, kubectl, kustomize, yq, python3 (the
# Nix shell of this repository has them) and a kubeconfig of the home cluster.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${root}/kubernetes/apps/hermes-sandbox/sandbox-tenant/app"
work="$(mktemp -d)"
pids=()
cleanup() {
  local code=$?
  if ((code != 0)); then
    tail -5 "${work}/etcd.log" "${work}/apiserver.log" 2>/dev/null >&2 || true
  fi
  for pid in "${pids[@]}"; do kill "${pid}" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "${work}"
}
trap cleanup EXIT

free_ports() {
  python3 -c 'import socket
socks = [socket.socket() for _ in range(3)]
for s in socks:
    s.bind(("127.0.0.1", 0))
print(*[s.getsockname()[1] for s in socks])'
}

crds=(gitrepositories.source.toolkit.fluxcd.io replicationsources.volsync.backube backups.postgresql.cnpg.io)
for crd in "${crds[@]}"; do
  kubectl get crd "${crd}" -o yaml |
    yq 'del(.status) | del(.metadata) | .metadata.name = "'"${crd}"'"' >"${work}/${crd}.yaml"
done
kustomize build "${app}" |
  yq 'select(.metadata.name == "hermes-dev-renovate" and (.kind == "ClusterRole" or .kind == "ClusterRoleBinding" or .kind == "ValidatingAdmissionPolicy" or .kind == "ValidatingAdmissionPolicyBinding"))' >"${work}/policy.yaml"

read -r etcd_port etcd_peer_port api_port < <(free_ports)

etcd --data-dir "${work}/etcd" \
  --listen-client-urls "http://127.0.0.1:${etcd_port}" \
  --advertise-client-urls "http://127.0.0.1:${etcd_port}" \
  --listen-peer-urls "http://127.0.0.1:${etcd_peer_port}" \
  >"${work}/etcd.log" 2>&1 &
pids+=("$!")

kubeadm init phase certs sa --cert-dir "${work}/pki" >/dev/null
echo "test-token,test,1,system:masters" >"${work}/tokens.csv"
kube-apiserver \
  --etcd-servers "http://127.0.0.1:${etcd_port}" \
  --bind-address 127.0.0.1 --secure-port "${api_port}" \
  --cert-dir "${work}/certs" \
  --service-account-key-file "${work}/pki/sa.pub" \
  --service-account-signing-key-file "${work}/pki/sa.key" \
  --service-account-issuer https://localhost \
  --service-cluster-ip-range 10.0.0.0/24 \
  --token-auth-file "${work}/tokens.csv" \
  --authorization-mode RBAC \
  >"${work}/apiserver.log" 2>&1 &
pids+=("$!")

kc() {
  kubectl --kubeconfig /dev/null --server "https://127.0.0.1:${api_port}" --token test-token \
    --insecure-skip-tls-verify "$@"
}
sa=(--as system:serviceaccount:hermes-sandbox:hermes-dev-renovate)

for _ in $(seq 1 120); do
  kc get --raw /readyz >/dev/null 2>&1 && break
  sleep 1
done
kc get --raw /readyz >/dev/null 2>&1 || {
  echo "FAIL: the API server did not start" >&2
  exit 1
}

for ns in apps flux-system database hermes-sandbox; do kc create namespace "${ns}" >/dev/null; done
# No controller makes the default account here, and a pod needs it.
kc -n apps create serviceaccount default >/dev/null
for crd in "${crds[@]}"; do
  kc create -f "${work}/${crd}.yaml" >/dev/null
  kc wait --for=condition=Established "crd/${crd}" --timeout=60s >/dev/null
done
kc create -f "${work}/policy.yaml" >/dev/null

# git_repo NAMESPACE NAME
git_repo() {
  kc apply -f - >/dev/null <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: $2
  namespace: $1
  labels: {app: demo}
spec:
  interval: 1h
  url: https://github.com/jaimemachadoneto/home-ops
  ref: {branch: main}
EOF
}
git_repo flux-system flux-system
git_repo apps other

kc apply -f - >/dev/null <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: demo
  namespace: apps
spec:
  sourcePVC: demo
  trigger: {schedule: "0 * * * *"}
  restic: {repository: demo-restic, copyMethod: Snapshot}
---
apiVersion: v1
kind: Pod
metadata: {name: demo, namespace: apps}
spec:
  containers: [{name: app, image: busybox}]
EOF

# backup NAMESPACE CLUSTER METHOD FILE: the Backup that backup.sh creates.
backup() {
  cat >"$4" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: {name: test, namespace: $1}
spec:
  cluster: {name: $2}
  method: $3
EOF
}
backup database postgres16 plugin "${work}/ok-backup.yaml"
backup database other plugin "${work}/other-cluster.yaml"
backup apps postgres16 plugin "${work}/other-ns.yaml"
backup database postgres16 volumeSnapshot "${work}/other-method.yaml"

failures=0

# verdict COMMAND...: "accepted", "refused" (by the policy), "forbidden" (by
# the role) or "error: ...".
verdict() {
  local out
  if out="$("$@" 2>&1)"; then
    echo accepted
  elif grep -q "ValidatingAdmissionPolicy 'hermes-dev-renovate'" <<<"${out}"; then
    echo refused
  elif grep -q "forbidden" <<<"${out}"; then
    echo forbidden
  else
    echo "error: ${out}"
  fi
}

# expect NAME RESULT COMMAND...
expect() {
  local name=$1 want=$2 got
  shift 2
  got="$(verdict "$@")"
  if [[ "${got}" == "${want}" ]]; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: expected ${want}, got ${got}" >&2
    failures=$((failures + 1))
  fi
}

gr=(gitrepository.source.toolkit.fluxcd.io)
rs=(replicationsource.volsync.backube)
dry=(--dry-run=server --type merge)

# The policy applies a moment after its creation: wait until it refuses a
# change of the URL.
for _ in $(seq 1 60); do
  [[ "$(verdict kc "${sa[@]}" -n flux-system patch "${gr[@]}" flux-system "${dry[@]}" -p '{"spec":{"url":"https://example.com"}}')" == refused ]] && break
  sleep 1
done

expect "reconcile flux-system" accepted \
  kc "${sa[@]}" -n flux-system patch "${gr[@]}" flux-system "${dry[@]}" -p '{"metadata":{"annotations":{"reconcile.fluxcd.io/requestedAt":"now"}}}'
expect "start a manual backup" accepted \
  kc "${sa[@]}" -n apps patch "${rs[@]}" demo "${dry[@]}" -p '{"spec":{"trigger":{"manual":"now"}}}'
kc -n apps patch "${rs[@]}" demo --type merge -p '{"spec":{"trigger":{"manual":"before"}}}' >/dev/null
expect "remove the manual trigger (backup.sh)" accepted \
  kc "${sa[@]}" -n apps patch "${rs[@]}" demo --dry-run=server --type json -p '[{"op":"remove","path":"/spec/trigger/manual"}]'
expect "create a Backup of postgres16" accepted \
  kc "${sa[@]}" create --dry-run=server -f "${work}/ok-backup.yaml"
expect "read pods" accepted kc "${sa[@]}" -n apps get pods
expect "read GitRepositories" accepted kc "${sa[@]}" get "${gr[@]}" -A

expect "change the URL of flux-system" refused \
  kc "${sa[@]}" -n flux-system patch "${gr[@]}" flux-system "${dry[@]}" -p '{"spec":{"url":"https://example.com/evil"}}'
expect "add another annotation to flux-system" refused \
  kc "${sa[@]}" -n flux-system patch "${gr[@]}" flux-system "${dry[@]}" -p '{"metadata":{"annotations":{"x":"y"}}}'
expect "change a label of flux-system" refused \
  kc "${sa[@]}" -n flux-system patch "${gr[@]}" flux-system "${dry[@]}" -p '{"metadata":{"labels":{"app":"evil"}}}'
expect "add a finalizer to flux-system" refused \
  kc "${sa[@]}" -n flux-system patch "${gr[@]}" flux-system "${dry[@]}" -p '{"metadata":{"finalizers":["example.com/block"]}}'
expect "change the schedule of a backup" refused \
  kc "${sa[@]}" -n apps patch "${rs[@]}" demo "${dry[@]}" -p '{"spec":{"trigger":{"schedule":"0 0 1 1 *"}}}'
expect "change the source PVC" refused \
  kc "${sa[@]}" -n apps patch "${rs[@]}" demo "${dry[@]}" -p '{"spec":{"sourcePVC":"other"}}'
expect "change the backup repository" refused \
  kc "${sa[@]}" -n apps patch "${rs[@]}" demo "${dry[@]}" -p '{"spec":{"restic":{"repository":"evil"}}}'
expect "Backup of another cluster" refused kc "${sa[@]}" create --dry-run=server -f "${work}/other-cluster.yaml"
expect "Backup in another namespace" refused kc "${sa[@]}" create --dry-run=server -f "${work}/other-ns.yaml"
expect "Backup with another method" refused kc "${sa[@]}" create --dry-run=server -f "${work}/other-method.yaml"

expect "the role: reconcile another GitRepository" forbidden \
  kc "${sa[@]}" -n apps patch "${gr[@]}" other "${dry[@]}" -p '{"metadata":{"annotations":{"reconcile.fluxcd.io/requestedAt":"now"}}}'
expect "the role: no Secret read" forbidden kc "${sa[@]}" -n apps get secrets
expect "the role: no pod delete" forbidden kc "${sa[@]}" -n apps delete pod demo --dry-run=server
expect "another account is not limited" accepted \
  kc -n flux-system patch "${gr[@]}" flux-system "${dry[@]}" -p '{"spec":{"url":"https://example.com/other"}}'

if ((failures > 0)); then
  echo "${failures} case(s) failed" >&2
  exit 1
fi
echo "all cases passed"
