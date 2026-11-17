---
name: add-app
description: Add a new application to the home-ops Kubernetes cluster - a Flux Kustomization and an app-template HelmRelease under kubernetes/apps/, with optional storage, secrets, a route, a Postgres database or an MCP server for LiteLLM. Use when the user asks to deploy, add or install an app or a service in the cluster.
---

# Add an app to the cluster

The app goes in `kubernetes/apps/<namespace>/<app>/`. Copy the structure of a
reference app. Do not invent a new layout.

| Reference app | Shows |
| --- | --- |
| `kubernetes/apps/network/echo-server` | A minimal app with no state |
| `kubernetes/apps/selfhosted/atuin` | Storage with `volsync`, a route, a non-root user |
| `kubernetes/apps/selfhosted/karakeep` | An ExternalSecret with `dataFrom` and `rewrite` |
| `kubernetes/apps/ai/email-triage` | An app with its own Postgres cluster (`components/cnpg`) |
| `kubernetes/apps/selfhosted/paperless/mcp/ciliumnetworkpolicy.yaml` | A network policy: ingress, egress, DNS and the Postgres reply rule |
| `kubernetes/apps/ai/ha-mcp` | An MCP server that the LiteLLM operator runs |

## 1. Get the facts

Ask the user for each fact that the request does not state:

1. The name of the app and its namespace (`ls kubernetes/apps/`).
2. The image and its tag. Read the tag from the upstream release page.
3. The port, and if the app gets a route: `envoy-internal` (default) or
   `envoy-external` (public).
4. The state: does the app keep files? Then it gets `volsync`.
5. The secrets: the name of the 1Password item and the exact names of its
   fields. Do not guess a field name. A wrong name can give an empty value
   in the Secret, and the app then fails later with a different error.
6. A Postgres database: yes or no.
7. The other Flux Kustomizations that the app needs.
8. For the network policy: which pods call the app, and which services and
   hosts the app calls.

## 2. Write `ks.yaml`

Copy `kubernetes/apps/selfhosted/atuin/ks.yaml`, then change it:

- `metadata.name`, `app.kubernetes.io/name`, `path`, `targetNamespace` and
  `postBuild.substitute.APP`: the name of the app and its namespace.
- Keep `substituteFrom: cluster-secrets`, `prune: true`, `interval: 1h`,
  `timeout: 5m` and `wait: false`.
- An app with state: keep `components: [../../../../components/volsync]`,
  the `dependsOn` on `rook-ceph-cluster` (namespace `rook-ceph`), and set
  `VOLSYNC_CLAIM` and `VOLSYNC_CAPACITY`. The defaults of the other
  variables are in `kubernetes/components/volsync/`.
- An app with no state: remove `components`, the `rook-ceph-cluster`
  dependency and the `VOLSYNC_*` values.
- An app with Postgres: see step 4. Do not use `spec.patches` in `ks.yaml`:
  `cluster-apps` replaces that list with the HelmRelease defaults, so the
  patch never applies. Put a patch in a component next to the app (see
  `litellm/postgres`).
- Set `wait: true` only when another Kustomization depends on this one.

## 3. Write `app/`

- `ocirepository.yaml`: copy it from the reference app. Set the chart
  version to the version that most apps use:

  ```sh
  grep -h "tag:" kubernetes/apps/*/*/app/ocirepository.yaml | sort | uniq -c | sort -rn | head -1
  ```

- `helmrelease.yaml`: copy `atuin/app/helmrelease.yaml`, then change the
  image, the port, the probes, the env and the route.
  - Keep `reloader.stakater.com/auto: "true"` on the controller.
  - Keep the non-root `securityContext` of the pod and of the container.
    Remove it only if the image cannot run as non-root, and tell the user.
  - With `readOnlyRootFilesystem: true`, add an `emptyDir` on `/tmp`.
  - A route: `hostnames: [<app>.${SECRET_DOMAIN}]`, and `parentRefs` with
    the gateway from step 1, `namespace: network` and `sectionName: https`.
    atuin uses `envoy-external`. Change it to `envoy-internal`, unless the
    user asks for a public app.
  - With `volsync`: `persistence.<name>.existingClaim` is the value of
    `VOLSYNC_CLAIM`.
- `externalsecret.yaml`, only if the app has secrets: copy
  `karakeep/app/externalsecret.yaml`. The store is `onepassword`. The Secret
  is `<app>-secret`. Each template key uses `.<app>_<field>`, with the real
  field names from step 1. If you do not know a field name, write
  `<FIXME: 1Password field name>` and tell the user.
- `kustomization.yaml`: list each file of `app/`.

Follow the key order of `.github/instructions/helmrelease.instructions.md`.

## 4. A Postgres database (only if the app needs one)

Each app has its own CloudNativePG cluster `<app>-postgres` in its namespace,
from `kubernetes/components/cnpg`. Copy `email-triage/ks.yaml`. Do not add a
database to `postgres16`: it is removed.

1. In `ks.yaml`, add the components `../../../../components/cnpg/pg18` and
   then `../../../../components/cnpg/initdb`, and a `dependsOn` on
   `cloudnative-pg-barman-cloud` (namespace `database`).
2. Set `CNPG_DATABASE` and `CNPG_OWNER` (use `_`, not `-`), and
   `CNPG_PASSWORD_ITEM` and `CNPG_PASSWORD_PROPERTY`: the 1Password item and
   field of the password of the owner.
3. Optional: `CNPG_INSTANCES: "2"` with `CNPG_PDB: "true"` for an app that
   other apps need. `CNPG_SIDECAR_MEMORY_LIMIT: 1Gi` for a database above
   about 200 MB: the backup sidecar runs out of memory at the default 256Mi.
   `CNPG_NAME` when the cluster must not have the name of `APP`.
4. The app connects to `<app>-postgres-rw.<namespace>.svc.cluster.local:5432`
   with the owner and the same 1Password field.
5. After the first backup of the cluster is complete, remove `cnpg/initdb`
   in a second PR. `cnpg/pg18` alone restores from the backup each time the
   cluster is made again. Until then, a delete of the cluster loses the data.

The component adds the backups, the PodMonitor and the alerts of the cluster.

## 5. A network policy

Each app on `envoy-external` gets a `ciliumnetworkpolicy.yaml` in `app/`. Add
one to an internal app when the user asks. Copy
`selfhosted/paperless/mcp/ciliumnetworkpolicy.yaml`. Write a
CiliumNetworkPolicy, not the `networkpolicies` values of app-template: only
the Cilium kind has HTTP path and DNS name rules.

- `endpointSelector`: `app.kubernetes.io/name: <app>`.
- Ingress: the gateway pods (namespace `network`, label
  `gateway.networking.k8s.io/gateway-name`), `host` for the kubelet probes,
  Prometheus (namespace `observability`, `app.kubernetes.io/name:
  prometheus`) if the app has a ServiceMonitor, and each pod from fact 8.
- Egress: kube-dns on port 53, and each destination from fact 8. Omit
  `egress` if you do not know the destinations: an empty egress blocks all.
- If the app calls a Service whose pods can run on the same node (for
  example its Postgres cluster), add an ingress `fromEndpoints` rule for
  those pods, with no port. With `socketLB.hostNamespaceOnly`, the reply of a
  same-node backend is a new ingress flow, and the policy drops it.
- After the deploy, look for drops with Hubble:
  `kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe
  --namespace <namespace> --verdict DROPPED --last 50`.

## 6. An MCP server for agents (only for an MCP server)

- The server runs as a `LiteLLMMCPServer` in `kubernetes/apps/ai/<app>/`.
  Copy `ha-mcp`: `spec.workload` makes the operator run the container. If
  the server already runs in another app, set `spec.url` and no workload
  (see `paperless-mcp`).
- `spec.alias` is the name that the harnesses use. Use lowercase and `_`.
- `.github/workflows/flux-local.yaml` validates each
  `kubernetes/apps/ai/*/app/mcpserver.yaml` with kubeconform. Name the file
  `mcpserver.yaml`.
- Tell the user that a project gets the server only after the alias is in
  `harness/mcp.yaml` of the workspace and in `mcp:` of `repos.yaml`.

## 7. Register the app

Add `./<app>/ks.yaml` to `resources` of
`kubernetes/apps/<namespace>/kustomization.yaml`, at the end of the list. For
a new namespace, copy the folder of a small namespace: its `namespace.yaml`
(keep `prune: disabled` and `name: _`) and its `kustomization.yaml` (keep the
`flux-alerts` and `cluster-secrets` components). `kubernetes/apps/` has no
`kustomization.yaml`: Flux finds each namespace folder itself.

## 8. Verify

```sh
kustomize build kubernetes/apps/<namespace>/<app>/app
kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://k8s-schemas.home-operations.com/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  kubernetes/apps/<namespace>/<app>/app/*.yaml
```

`${SECRET_DOMAIN}` and the other `${VARS}` stay literal in the output. That is
correct: Flux replaces them. The `volsync` and `cnpg` components are not in
this output, because `ks.yaml` adds them. Show the files to the user before the commit. CI runs
flux-local on the PR. Read its diff.

## Common mistakes

| Mistake | Correct rule |
| --- | --- |
| A version from memory or from this file | Read the chart version from the repo and the image tag from upstream. |
| `onepassword-connect` as the store | The store of this cluster is `onepassword`. |
| A guessed 1Password field name | Ask the user. A wrong name can give an empty value in the Secret. |
| No `reloader.stakater.com/auto` | A change to the Secret does not restart the pod. |
| `readOnlyRootFilesystem` with no `/tmp` | The app fails when it writes a temporary file. |
| `existingClaim` that is not `VOLSYNC_CLAIM` | The pod waits for a PVC that does not exist. |
| A rename of an app later | Flux deletes the old resources, and the PVC with them. Ask the user first. |
| A new database in `postgres16` | Each app has its own cluster from `components/cnpg`. |
| `cnpg/pg18` with no `cnpg/initdb` for a new app | The cluster tries to restore a backup that does not exist, and does not start. |
| `cnpg/initdb` kept after the first backup | Remove it. Otherwise a cluster made again starts empty instead of from the backup. |
| A patch in `spec.patches` of `ks.yaml` | `cluster-apps` replaces the list. Use a component next to the app. |
| A network policy with no rule for a same-node Postgres reply | The app times out on its database. |
