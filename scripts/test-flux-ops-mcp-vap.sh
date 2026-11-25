#!/usr/bin/env bash
# Test what the account flux-ops-mcp can change: its role and the admission
# policy flux-ops-mcp (kubernetes/apps/ai/flux-ops-mcp/app). The script starts
# a temporary kube-apiserver and etcd on localhost, like
# test-hermes-sandbox-vap.sh. It copies the Flux CRDs of Kustomization and
# GitRepository from the home cluster (read only), installs the role and the
# policy that the app renders, and sends each request as the account with
# `--dry-run=server`, so nothing is stored. The test fails when the account
# can make a change that it must not make, or cannot make an allowed one.
# Run it by hand or with `just test-flux-ops-mcp-vap`. CI does not run it.
# Needs: etcd, kube-apiserver, kubeadm, kubectl, kustomize, yq, python3 (the
# Nix shell of this repository has them) and a kubeconfig of the home cluster.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${root}/kubernetes/apps/ai/flux-ops-mcp/app"
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

# Render and copy first. A broken app then fails before the servers start.
for crd in kustomizations.kustomize.toolkit.fluxcd.io gitrepositories.source.toolkit.fluxcd.io; do
  kubectl get crd "${crd}" -o yaml |
    yq 'del(.status) | del(.metadata) | .metadata.name = "'"${crd}"'"' >"${work}/${crd}.yaml"
done
kustomize build "${app}" |
  yq 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding" or .kind == "ValidatingAdmissionPolicy" or .kind == "ValidatingAdmissionPolicyBinding")' >"${work}/policy.yaml"

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
sa=(--as system:serviceaccount:ai:flux-ops-mcp)

for _ in $(seq 1 120); do
  kc get --raw /readyz >/dev/null 2>&1 && break
  sleep 1
done
kc get --raw /readyz >/dev/null 2>&1 || {
  echo "FAIL: the API server did not start" >&2
  exit 1
}

for ns in ai apps flux-system; do kc create namespace "${ns}" >/dev/null; done
# No controller makes the default account here, and a pod needs it.
for ns in apps kube-system; do kc -n "${ns}" create serviceaccount default >/dev/null; done
for crd in kustomizations.kustomize.toolkit.fluxcd.io gitrepositories.source.toolkit.fluxcd.io; do
  kc create -f "${work}/${crd}.yaml" >/dev/null
  kc wait --for=condition=Established "crd/${crd}" --timeout=60s >/dev/null
done
kc create -f "${work}/policy.yaml" >/dev/null

for ns in apps flux-system; do
  kc apply -f - >/dev/null <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: demo
  namespace: ${ns}
  labels: {app: demo}
spec:
  interval: 1h
  path: ./apps/demo
  prune: true
  timeout: 5m
  sourceRef: {kind: GitRepository, name: flux-system, namespace: flux-system}
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: demo
  namespace: ${ns}
spec:
  interval: 1h
  url: https://github.com/jaimemachadoneto/home-ops
  ref: {branch: main}
EOF
done

# pod NAMESPACE NAME OWNED [LABELS]: a pod with no node; it only needs to exist.
pod() {
  local owner=""
  [[ "$3" == yes ]] && owner='ownerReferences: [{apiVersion: apps/v1, kind: ReplicaSet, name: rs, uid: 00000000-0000-0000-0000-000000000001, controller: true}]'
  kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $2
  namespace: $1
  labels: {${4:-app: demo}}
  ${owner}
spec:
  containers: [{name: app, image: busybox}]
EOF
}
pod apps owned yes
pod apps bare no
pod apps postgres yes "cnpg.io/cluster: app-postgres"
pod kube-system owned yes

failures=0

# verdict COMMAND...: "accepted", "refused" (by the policy), "forbidden" (by
# the role) or "error: ...".
verdict() {
  local out
  if out="$("$@" 2>&1)"; then
    echo accepted
  elif grep -q "ValidatingAdmissionPolicy 'flux-ops-mcp'" <<<"${out}"; then
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

ks=(kustomization.kustomize.toolkit.fluxcd.io)
gr=(gitrepository.source.toolkit.fluxcd.io)
dry=(--dry-run=server --type merge)

# The policy applies a moment after its creation: wait until it refuses a
# change of spec.path.
for _ in $(seq 1 60); do
  [[ "$(verdict kc "${sa[@]}" -n apps patch "${ks[@]}" demo "${dry[@]}" -p '{"spec":{"path":"./x"}}')" == refused ]] && break
  sleep 1
done

expect "reconcile annotation" accepted \
  kc "${sa[@]}" -n apps patch "${ks[@]}" demo "${dry[@]}" -p '{"metadata":{"annotations":{"reconcile.fluxcd.io/requestedAt":"now"}}}'
expect "reconcile of a source" accepted \
  kc "${sa[@]}" -n apps patch "${gr[@]}" demo "${dry[@]}" -p '{"metadata":{"annotations":{"reconcile.fluxcd.io/requestedAt":"now"}}}'
expect "suspend in apps" accepted \
  kc "${sa[@]}" -n apps patch "${ks[@]}" demo "${dry[@]}" -p '{"spec":{"suspend":true}}'
expect "resume in flux-system" accepted \
  kc "${sa[@]}" -n flux-system patch "${ks[@]}" demo "${dry[@]}" -p '{"spec":{"suspend":false}}'
expect "delete an owned pod" accepted \
  kc "${sa[@]}" -n apps delete pod owned --dry-run=server

expect "change spec.path" refused \
  kc "${sa[@]}" -n apps patch "${ks[@]}" demo "${dry[@]}" -p '{"spec":{"path":"./evil"}}'
expect "add a spec field" refused \
  kc "${sa[@]}" -n apps patch "${ks[@]}" demo "${dry[@]}" -p '{"spec":{"targetNamespace":"kube-system"}}'
expect "remove a spec field" refused \
  kc "${sa[@]}" -n apps patch "${ks[@]}" demo "${dry[@]}" -p '{"spec":{"timeout":null}}'
expect "change a GitRepository URL" refused \
  kc "${sa[@]}" -n apps patch "${gr[@]}" demo "${dry[@]}" -p '{"spec":{"url":"https://example.com/evil"}}'
expect "change a label" refused \
  kc "${sa[@]}" -n apps patch "${ks[@]}" demo "${dry[@]}" -p '{"metadata":{"labels":{"app":"evil"}}}'
expect "add another annotation" refused \
  kc "${sa[@]}" -n apps patch "${ks[@]}" demo "${dry[@]}" -p '{"metadata":{"annotations":{"kustomize.toolkit.fluxcd.io/reconcile":"disabled"}}}'
expect "suspend in flux-system" refused \
  kc "${sa[@]}" -n flux-system patch "${ks[@]}" demo "${dry[@]}" -p '{"spec":{"suspend":true}}'
expect "delete a pod without an owner" refused \
  kc "${sa[@]}" -n apps delete pod bare --dry-run=server
expect "delete a CNPG pod" refused \
  kc "${sa[@]}" -n apps delete pod postgres --dry-run=server
expect "delete a pod in kube-system" refused \
  kc "${sa[@]}" -n kube-system delete pod owned --dry-run=server

expect "the role: no Deployment change" forbidden \
  kc "${sa[@]}" -n apps create deployment x --image=busybox --dry-run=server
expect "the role: no Secret read" forbidden \
  kc "${sa[@]}" -n apps get secrets
expect "another account is not limited" accepted \
  kc -n apps patch "${ks[@]}" demo "${dry[@]}" -p '{"spec":{"path":"./other"}}'

if ((failures > 0)); then
  echo "${failures} case(s) failed" >&2
  exit 1
fi
echo "all cases passed"
