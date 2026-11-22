#!/usr/bin/env bash
# Test the admission policy hermes-sandbox-pod against a good Sandbox and
# against bad ones. The script starts a throwaway kube-apiserver and etcd on
# localhost, with no cluster and no kubelet. It installs the Sandbox CRD that
# home-ops installs and the policy that the app renders. It then sends each
# Sandbox with `--dry-run=server`, so that the real CEL engine of the API
# server evaluates the policy and nothing is stored. A bad Sandbox that the
# policy accepts, or a good one that it refuses, fails the test.
# Needs: etcd, kube-apiserver, kubeadm, kubectl, kustomize, yq, python3
# (the Nix shell of this repository has them) and network access, because
# kustomize downloads the manifest of the agent-sandbox release.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${root}/kubernetes/apps/hermes-sandbox/sandbox-tenant/app"
crd_app="${root}/kubernetes/apps/agent-sandbox-system/agent-sandbox/app"
good="${root}/tests/hermes-sandbox/sandbox-good.yaml"
work="$(mktemp -d)"
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "${pid}" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "${work}"
}
trap cleanup EXIT

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# Render the objects first, so that a broken app fails before the servers start.
kustomize build "${crd_app}" |
  yq 'select(.kind == "CustomResourceDefinition" and .spec.names.kind == "Sandbox")' >"${work}/crd.yaml"
kustomize build "${app}" |
  yq 'select(.kind == "ValidatingAdmissionPolicy" or .kind == "ValidatingAdmissionPolicyBinding")' >"${work}/policy.yaml"
if ! grep -q 'kind: ValidatingAdmissionPolicy$' "${work}/policy.yaml"; then
  echo "FAIL: the app renders no ValidatingAdmissionPolicy" >&2
  exit 1
fi

etcd_port="$(free_port)"
etcd_peer_port="$(free_port)"
api_port="$(free_port)"

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
  kubectl --server "https://127.0.0.1:${api_port}" --token test-token \
    --insecure-skip-tls-verify "$@"
}

for _ in $(seq 1 120); do
  kc get --raw /readyz >/dev/null 2>&1 && break
  sleep 1
done
kc get --raw /readyz >/dev/null 2>&1 || {
  echo "FAIL: the API server did not start" >&2
  tail -20 "${work}/apiserver.log" >&2
  exit 1
}

kc create namespace hermes-sandbox >/dev/null
kc create -f "${work}/crd.yaml" >/dev/null
kc wait --for=condition=Established crd/sandboxes.agents.x-k8s.io --timeout=60s >/dev/null
kc create -f "${work}/policy.yaml" >/dev/null

failures=0

# verdict <file>: print "accepted", "refused" (by the policy) or "error: ...".
verdict() {
  local out
  if out="$(kc create --dry-run=server -f "$1" 2>&1)"; then
    echo accepted
  elif grep -q "ValidatingAdmissionPolicy 'hermes-sandbox-pod'" <<<"${out}"; then
    echo refused
  else
    echo "error: ${out}"
  fi
}

# The policy starts to apply a moment after its creation. Wait until the
# policy refuses a Sandbox without a pod account, so that no case passes
# because the policy is not active yet.
yq "del(.spec.podTemplate.spec.serviceAccountName)" "${good}" >"${work}/probe.yaml"
for _ in $(seq 1 60); do
  [[ "$(verdict "${work}/probe.yaml")" == refused ]] && break
  sleep 1
done
[[ "$(verdict "${work}/probe.yaml")" == refused ]] || {
  echo "FAIL: the policy did not become active" >&2
  exit 1
}

# expect <name> <accepted|refused> <file>
expect() {
  local got
  got="$(verdict "$3")"
  if [[ "${got}" == "$2" ]]; then
    echo "ok   ${1}"
  else
    echo "FAIL ${1}: expected ${2}, got ${got}" >&2
    failures=$((failures + 1))
  fi
}

# bad <name> <yq expression>: change the good Sandbox and expect a refusal.
bad() {
  yq "$2" "${good}" >"${work}/bad.yaml"
  expect "$1" refused "${work}/bad.yaml"
}

pod='.spec.podTemplate.spec'

expect "good sandbox" accepted "${good}"

bad "wrong image" "${pod}.containers[0].image = \"docker.io/library/alpine:3\""
bad "wrong image prefix without slash" "${pod}.containers[0].image = \"ghcr.io/jaimemachadoneto/hermes-sandbox-evil:1\""
bad "wrong init image" "${pod}.initContainers[0].image = \"docker.io/library/alpine:3\""
bad "wrong service account" "${pod}.serviceAccountName = \"default\""
bad "no service account" "del(${pod}.serviceAccountName)"
bad "token mounted" "${pod}.automountServiceAccountToken = true"
bad "token setting missing" "del(${pod}.automountServiceAccountToken)"
bad "hostPath volume" "${pod}.volumes += [{\"name\": \"h\", \"hostPath\": {\"path\": \"/\"}}]"
bad "secret volume" "${pod}.volumes += [{\"name\": \"s\", \"secret\": {\"secretName\": \"ghcr-pull\"}}]"
bad "projected token volume" "${pod}.volumes += [{\"name\": \"t\", \"projected\": {\"sources\": [{\"serviceAccountToken\": {\"path\": \"t\"}}]}}]"
bad "persistentVolumeClaim volume" "${pod}.volumes += [{\"name\": \"p\", \"persistentVolumeClaim\": {\"claimName\": \"other\"}}]"
bad "emptyDir without sizeLimit" "del(${pod}.volumes[0].emptyDir.sizeLimit)"
bad "emptyDir in memory" "${pod}.volumes[0].emptyDir.medium = \"Memory\""
bad "wrong pull secret" "${pod}.imagePullSecrets[0].name = \"other\""
bad "extra pull secret" "${pod}.imagePullSecrets += [{\"name\": \"other\"}]"
bad "no home-ops-03 affinity" "del(${pod}.affinity)"
bad "affinity with In operator" "${pod}.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator = \"In\""
bad "affinity for another node" "${pod}.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values = [\"home-ops-01\"]"
bad "second affinity term without exclusion" "${pod}.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms += [{\"matchExpressions\": [{\"key\": \"kubernetes.io/arch\", \"operator\": \"In\", \"values\": [\"amd64\"]}]}]"
bad "preferred affinity only" "${pod}.affinity.nodeAffinity = {\"preferredDuringSchedulingIgnoredDuringExecution\": [{\"weight\": 1, \"preference\": {\"matchExpressions\": [{\"key\": \"kubernetes.io/hostname\", \"operator\": \"NotIn\", \"values\": [\"home-ops-03\"]}]}}]}"
bad "nodeName set" "${pod}.nodeName = \"home-ops-03\""
bad "init container with another name" "${pod}.initContainers[0].name = \"setup\""
bad "second init container" "${pod}.initContainers += [${pod}.initContainers[0] | .name = \"second\"]"
bad "ephemeral container" "${pod}.ephemeralContainers = [{\"name\": \"debug\", \"image\": \"ghcr.io/jaimemachadoneto/hermes-sandbox:1\"}]"
bad "hostNetwork" "${pod}.hostNetwork = true"
bad "hostPID" "${pod}.hostPID = true"
bad "env from a Secret key" "${pod}.containers[0].env = [{\"name\": \"X\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"ghcr-pull\", \"key\": \"k\"}}}]"
bad "envFrom a Secret" "${pod}.containers[0].envFrom = [{\"secretRef\": {\"name\": \"ghcr-pull\"}}]"
bad "volume template with another class" ".spec.volumeClaimTemplates[0].spec.storageClassName = \"openebs-hostpath\""
bad "volume template from a PVC" ".spec.volumeClaimTemplates[0].spec.dataSource = {\"kind\": \"PersistentVolumeClaim\", \"name\": \"other\"}"
bad "volume template from another API group" ".spec.volumeClaimTemplates[0].spec.dataSource.apiGroup = \"example.com\""
bad "volume template with dataSourceRef of another namespace" ".spec.volumeClaimTemplates[0].spec.dataSourceRef = {\"apiGroup\": \"snapshot.storage.k8s.io\", \"kind\": \"VolumeSnapshot\", \"name\": \"x\", \"namespace\": \"other\"}"
bad "volume template over 20Gi" ".spec.volumeClaimTemplates[0].spec.resources.requests.storage = \"50Gi\""
bad "volume template with a volumeName" ".spec.volumeClaimTemplates[0].spec.volumeName = \"pv-1\""

# A volume template without a data source is valid: the Nix base can be absent.
yq "del(.spec.volumeClaimTemplates[0].spec.dataSource)" "${good}" >"${work}/nodatasource.yaml"
expect "volume template without data source" accepted "${work}/nodatasource.yaml"

if ((failures > 0)); then
  echo "${failures} case(s) failed" >&2
  exit 1
fi
echo "all cases passed"
