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
| `kubernetes/apps/selfhosted/paperless` (`mcp` part) | An app that uses the Postgres cluster |
| `kubernetes/apps/database/cloudnative-pg/cluster/paperless-mcp.yaml` | The `Database` and the password of an app |
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
- An app with Postgres: add a `dependsOn` on `cloudnative-pg-cluster`
  (namespace `database`).
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

1. Copy `kubernetes/apps/database/cloudnative-pg/cluster/paperless-mcp.yaml`
   to `<app>.yaml` in that folder. It holds the ExternalSecret of the
   password and the `Database`. Keep `databaseReclaimPolicy: retain`.
2. Add the file to `kustomization.yaml` of that folder.
3. Add the role to `managed.roles` of `cluster16.yaml`, with a comment that
   names the app. The password comes from the Secret of step 1.
4. The app reads the same 1Password field for its connection string.
5. Tell the user: this changes the shared `postgres16` cluster, and the role
   and the database come up at the next reconcile.

## 5. An MCP server for agents (only for an MCP server)

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

## 6. Register the app

Add `./<app>/ks.yaml` to `resources` of
`kubernetes/apps/<namespace>/kustomization.yaml`, at the end of the list. For
a new namespace, copy the folder of a small namespace: its `namespace.yaml`
(keep `prune: disabled` and `name: _`) and its `kustomization.yaml` (keep the
`flux-alerts` and `sops` components). `kubernetes/apps/` has no
`kustomization.yaml`: Flux finds each namespace folder itself.

## 7. Verify

```sh
kustomize build kubernetes/apps/<namespace>/<app>/app
kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://k8s-schemas.home-operations.com/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  kubernetes/apps/<namespace>/<app>/app/*.yaml
```

`${SECRET_DOMAIN}` and the other `${VARS}` stay literal in the output. That is
correct: Flux replaces them. The `volsync` component is not in this output,
because `ks.yaml` adds it. Show the files to the user before the commit. CI runs
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
