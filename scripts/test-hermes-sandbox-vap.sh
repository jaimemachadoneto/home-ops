#!/usr/bin/env bash
# Test the admission policy hermes-sandbox-pod against a good Sandbox and
# against bad ones. The script starts a temporary kube-apiserver and etcd on
# localhost. It needs no cluster and no kubelet. It installs the Sandbox CRD
# that home-ops installs and the policy that the app renders. It then sends
# each Sandbox with `--dry-run=server`, so that the CEL engine of the API
# server evaluates the policy and nothing is stored. The test fails when the
# policy accepts a bad Sandbox or refuses a good Sandbox. A refusal counts
# only when the message of the expected rule is in the answer.
# Run it by hand or with `just test-hermes-sandbox-vap`. CI does not run it.
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
  local code=$?
  if ((code != 0)); then
    tail -5 "${work}/etcd.log" "${work}/apiserver.log" 2>/dev/null >&2 || true
  fi
  for pid in "${pids[@]}"; do kill "${pid}" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "${work}"
}
trap cleanup EXIT

# Hold the three sockets together, so that the ports are different.
free_ports() {
  python3 -c 'import socket
socks = [socket.socket() for _ in range(3)]
for s in socks:
    s.bind(("127.0.0.1", 0))
print(*[s.getsockname()[1] for s in socks])'
}

# Render the objects first. A broken app then fails before the servers start.
kustomize build "${crd_app}" |
  yq 'select(.kind == "CustomResourceDefinition" and .spec.names.kind == "Sandbox")' >"${work}/crd.yaml"
kustomize build "${app}" |
  yq 'select(.kind == "ValidatingAdmissionPolicy" or .kind == "ValidatingAdmissionPolicyBinding")' >"${work}/policy.yaml"
if ! grep -q 'kind: ValidatingAdmissionPolicy$' "${work}/policy.yaml" ||
  ! grep -q 'kind: ValidatingAdmissionPolicyBinding$' "${work}/policy.yaml"; then
  echo "FAIL: the app renders no policy or no binding" >&2
  exit 1
fi

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

# verdict <file> <message>: print "accepted", "refused" (the policy refused
# with the message) or "error: ..." (any other result).
verdict() {
  local out
  if out="$(kc create --dry-run=server -f "$1" 2>&1)"; then
    echo accepted
  elif grep -q "ValidatingAdmissionPolicy 'hermes-sandbox-pod'.*${2:-}" <<<"${out}"; then
    echo refused
  else
    echo "error: ${out}"
  fi
}

# The policy starts to apply a moment after its creation. Wait until the
# policy refuses a Sandbox with no pod account. Then no case passes before
# the policy is active.
yq "del(.spec.podTemplate.spec.serviceAccountName)" "${good}" >"${work}/probe.yaml"
for _ in $(seq 1 60); do
  [[ "$(verdict "${work}/probe.yaml")" == refused ]] && break
  sleep 1
done
[[ "$(verdict "${work}/probe.yaml")" == refused ]] || {
  echo "FAIL: the policy did not become active" >&2
  exit 1
}

# expect <name> <accepted|refused> <file> [message]
expect() {
  local got
  got="$(verdict "$3" "${4:-}")"
  if [[ "${got}" == "$2" ]]; then
    echo "ok   ${1}"
  else
    echo "FAIL ${1}: expected ${2}, got ${got}" >&2
    failures=$((failures + 1))
  fi
}

# bad <name> <yq expression> <message>: change the good Sandbox and expect a
# refusal by the rule that has the message.
bad() {
  yq "$2" "${good}" >"${work}/bad.yaml"
  expect "$1" refused "${work}/bad.yaml" "$3"
}

# ok <name> <yq expression>: change the good Sandbox and expect an acceptance.
ok() {
  yq "$2" "${good}" >"${work}/ok.yaml"
  expect "$1" accepted "${work}/ok.yaml"
}

pod='.spec.podTemplate.spec'
vct='.spec.volumeClaimTemplates[0].spec'
aff="${pod}.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution"

m_account="does not mount its token"
m_host="no host network"
m_volume="only emptyDir volumes"
m_template="A volume template uses"
m_init="no ephemeral container"
m_image="runs the image"
m_pull="only with the Secret ghcr-pull"
m_affinity="excludes the node"
m_fields="sets no scheduling field"

expect "good sandbox" accepted "${good}"

ok "no init container" "del(${pod}.initContainers)"
ok "image without a tag" "${pod}.containers[0].image = \"ghcr.io/jaimemachadoneto/hermes-sandbox\""
ok "image with a digest and no tag" "${pod}.containers[0].image = \"ghcr.io/jaimemachadoneto/hermes-sandbox@sha256:0000000000000000000000000000000000000000000000000000000000000000\""
ok "plain env value" "${pod}.containers[0].env = [{\"name\": \"X\", \"value\": \"1\"}]"
ok "affinity with more values" "${aff}.nodeSelectorTerms[0].matchExpressions[0].values += [\"home-ops-02\"]"
ok "volume template without data source" "del(${vct}.dataSource)"
ok "volume template with a data source reference" "del(${vct}.dataSource) | ${vct}.dataSourceRef = {\"apiGroup\": \"snapshot.storage.k8s.io\", \"kind\": \"VolumeSnapshot\", \"name\": \"x\"}"

bad "wrong image" "${pod}.containers[0].image = \"docker.io/library/alpine:3\"" "${m_image}"
bad "image name that extends the allowed name" "${pod}.containers[0].image = \"ghcr.io/jaimemachadoneto/hermes-sandbox-evil:1\"" "${m_image}"
bad "second container with a wrong image" "${pod}.containers += [${pod}.containers[0] | .name = \"second\" | .image = \"docker.io/library/alpine:3\"]" "${m_image}"
bad "wrong init image" "${pod}.initContainers[0].image = \"docker.io/library/alpine:3\"" "${m_image}"
bad "env from a Secret key" "${pod}.containers[0].env = [{\"name\": \"X\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"ghcr-pull\", \"key\": \"k\"}}}]" "${m_image}"
bad "envFrom a Secret" "${pod}.containers[0].envFrom = [{\"secretRef\": {\"name\": \"ghcr-pull\"}}]" "${m_image}"
bad "init container env from a Secret key" "${pod}.initContainers[0].env = [{\"name\": \"X\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"ghcr-pull\", \"key\": \"k\"}}}]" "${m_image}"
bad "init container envFrom" "${pod}.initContainers[0].envFrom = [{\"configMapRef\": {\"name\": \"x\"}}]" "${m_image}"

bad "wrong service account" "${pod}.serviceAccountName = \"default\"" "${m_account}"
bad "no service account" "del(${pod}.serviceAccountName)" "${m_account}"
bad "token mounted" "${pod}.automountServiceAccountToken = true" "${m_account}"
bad "token setting missing" "del(${pod}.automountServiceAccountToken)" "${m_account}"

bad "hostPath volume" "${pod}.volumes += [{\"name\": \"h\", \"hostPath\": {\"path\": \"/\"}}]" "${m_volume}"
bad "secret volume" "${pod}.volumes += [{\"name\": \"s\", \"secret\": {\"secretName\": \"ghcr-pull\"}}]" "${m_volume}"
bad "projected token volume" "${pod}.volumes += [{\"name\": \"t\", \"projected\": {\"sources\": [{\"serviceAccountToken\": {\"path\": \"t\"}}]}}]" "${m_volume}"
bad "persistentVolumeClaim volume" "${pod}.volumes += [{\"name\": \"p\", \"persistentVolumeClaim\": {\"claimName\": \"other\"}}]" "${m_volume}"
bad "emptyDir without sizeLimit" "del(${pod}.volumes[0].emptyDir.sizeLimit)" "${m_volume}"
bad "emptyDir in memory" "${pod}.volumes[0].emptyDir.medium = \"Memory\"" "${m_volume}"

bad "wrong pull secret" "${pod}.imagePullSecrets[0].name = \"other\"" "${m_pull}"
bad "extra pull secret" "${pod}.imagePullSecrets += [{\"name\": \"other\"}]" "${m_pull}"

bad "no home-ops-03 affinity" "del(${pod}.affinity)" "${m_affinity}"
bad "affinity with In operator" "${aff}.nodeSelectorTerms[0].matchExpressions[0].operator = \"In\"" "${m_affinity}"
bad "affinity for another node" "${aff}.nodeSelectorTerms[0].matchExpressions[0].values = [\"home-ops-01\"]" "${m_affinity}"
bad "affinity without values" "del(${aff}.nodeSelectorTerms[0].matchExpressions[0].values)" "${m_affinity}"
bad "affinity with matchFields only" "${aff}.nodeSelectorTerms = [{\"matchFields\": [{\"key\": \"metadata.name\", \"operator\": \"NotIn\", \"values\": [\"home-ops-03\"]}]}]" "${m_affinity}"
bad "second affinity term without exclusion" "${aff}.nodeSelectorTerms += [{\"matchExpressions\": [{\"key\": \"kubernetes.io/arch\", \"operator\": \"In\", \"values\": [\"amd64\"]}]}]" "${m_affinity}"
bad "first affinity term without exclusion" "${aff}.nodeSelectorTerms = [{\"matchExpressions\": [{\"key\": \"kubernetes.io/arch\", \"operator\": \"In\", \"values\": [\"amd64\"]}]}] + ${aff}.nodeSelectorTerms" "${m_affinity}"
bad "preferred affinity only" "${pod}.affinity.nodeAffinity = {\"preferredDuringSchedulingIgnoredDuringExecution\": [{\"weight\": 1, \"preference\": {\"matchExpressions\": [{\"key\": \"kubernetes.io/hostname\", \"operator\": \"NotIn\", \"values\": [\"home-ops-03\"]}]}}]}" "${m_affinity}"

bad "nodeName set" "${pod}.nodeName = \"home-ops-03\"" "${m_host}"
bad "hostNetwork" "${pod}.hostNetwork = true" "${m_host}"
bad "hostPID" "${pod}.hostPID = true" "${m_host}"
bad "hostIPC" "${pod}.hostIPC = true" "${m_host}"

bad "toleration" "${pod}.tolerations = [{\"operator\": \"Exists\"}]" "${m_fields}"
bad "nodeSelector" "${pod}.nodeSelector = {\"kubernetes.io/hostname\": \"home-ops-01\"}" "${m_fields}"
bad "priorityClassName" "${pod}.priorityClassName = \"system-node-critical\"" "${m_fields}"
bad "runtimeClassName" "${pod}.runtimeClassName = \"x\"" "${m_fields}"
bad "schedulerName" "${pod}.schedulerName = \"x\"" "${m_fields}"
bad "shareProcessNamespace" "${pod}.shareProcessNamespace = true" "${m_fields}"

bad "init container with another name" "${pod}.initContainers[0].name = \"setup\"" "${m_init}"
bad "second init container" "${pod}.initContainers += [${pod}.initContainers[0] | .name = \"second\"]" "${m_init}"
bad "ephemeral container" "${pod}.ephemeralContainers = [{\"name\": \"debug\", \"image\": \"ghcr.io/jaimemachadoneto/hermes-sandbox:1\"}]" "${m_init}"

bad "volume template with another class" "${vct}.storageClassName = \"openebs-hostpath\"" "${m_template}"
bad "volume template without a class" "del(${vct}.storageClassName)" "${m_template}"
bad "volume template from a PVC" "${vct}.dataSource.kind = \"PersistentVolumeClaim\" | ${vct}.dataSource.apiGroup = \"snapshot.storage.k8s.io\"" "${m_template}"
bad "volume template from another API group" "${vct}.dataSource.apiGroup = \"example.com\"" "${m_template}"
bad "volume template with a reference of another kind" "del(${vct}.dataSource) | ${vct}.dataSourceRef = {\"apiGroup\": \"snapshot.storage.k8s.io\", \"kind\": \"PersistentVolumeClaim\", \"name\": \"x\"}" "${m_template}"
bad "volume template with a reference of another namespace" "${vct}.dataSourceRef = {\"apiGroup\": \"snapshot.storage.k8s.io\", \"kind\": \"VolumeSnapshot\", \"name\": \"x\", \"namespace\": \"other\"}" "${m_template}"
bad "volume template over 20Gi" "${vct}.resources.requests.storage = \"50Gi\"" "${m_template}"
bad "volume template without a size" "del(${vct}.resources)" "${m_template}"
bad "volume template with a volumeName" "${vct}.volumeName = \"pv-1\"" "${m_template}"
bad "volume template with a selector" "${vct}.selector = {\"matchLabels\": {\"a\": \"b\"}}" "${m_template}"
bad "volume template with a block volume" "${vct}.volumeMode = \"Block\"" "${m_template}"
bad "volume template with ReadWriteMany" "${vct}.accessModes = [\"ReadWriteMany\"]" "${m_template}"
bad "second volume template that is bad" ".spec.volumeClaimTemplates += [.spec.volumeClaimTemplates[0] | .metadata.name = \"second\" | .spec.storageClassName = \"openebs-hostpath\"]" "${m_template}"

# A bad change of a stored Sandbox: the policy covers UPDATE.
kc create -f "${good}" >/dev/null
yq "${pod}.serviceAccountName = \"default\"" "${good}" >"${work}/update.yaml"
if out="$(kc replace --dry-run=server -f "${work}/update.yaml" 2>&1)" ||
  ! grep -q "ValidatingAdmissionPolicy 'hermes-sandbox-pod'.*${m_account}" <<<"${out}"; then
  echo "FAIL update to a wrong service account: expected refused, got: ${out}" >&2
  failures=$((failures + 1))
else
  echo "ok   update to a wrong service account"
fi

# The policy binds only to hermes-sandbox. This case fixes that boundary.
kc create namespace other >/dev/null
yq "${pod}.serviceAccountName = \"default\" | .metadata.namespace = \"other\"" "${good}" >"${work}/other.yaml"
expect "bad sandbox in another namespace is out of scope" accepted "${work}/other.yaml"

if ((failures > 0)); then
  echo "${failures} case(s) failed" >&2
  exit 1
fi
echo "all cases passed"
