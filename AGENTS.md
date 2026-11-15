# home-ops

GitOps repository for the home Kubernetes cluster (Talos, Flux, Renovate) and
for the Docker hosts next to it. The workspace rules in `~/Projects/AGENTS.md`
also apply here. This file gives the rules of this repository only.

## Repository map

| Path | Holds |
| --- | --- |
| `kubernetes/apps/<namespace>/<app>/` | One app: `ks.yaml` (the Flux Kustomization) and `app/` (the HelmRelease and its resources) |
| `kubernetes/apps/<namespace>/kustomization.yaml` | The list of the apps of a namespace, and the components of the namespace |
| `kubernetes/components/` | Kustomize components: `volsync`, `sops`, `flux-alerts`, `gpu`, `keda/nas-nfs-scaler` |
| `kubernetes/flux/cluster/ks.yaml` | The Flux entry point, and the HelmRelease defaults that it adds to each app |
| `kubernetes/talos/` | The Talos machine config template (`machineconfig.yaml.j2`), a node file and a schematic for each node, and `mod.just` |
| `kubernetes/bootstrap/` | The Helmfile and the recipes that start a new cluster |
| `hosts/ai/`, `hosts/semaphore/` | The Docker hosts: Compose stacks, doco-cd, and their READMEs |
| `.doco-cd.<target>.yml` | The stacks that doco-cd deploys from `main`, one document for each stack |
| `ansible/` | Playbooks and roles for the hosts |
| `.renovate/`, `renovate.json5` | The Renovate presets of this repository |
| `.github/workflows/` | CI: flux-local, lint, CodeQL, pre-pull of images, labels, Pages |
| `.claude/skills/`, `.claude/agents/` | The skills and agents of this repository (see "Task guidance") |
| `docs/` | The design notes: storage, network, AI host, backups, and more |

Use `just` for the operational commands (`just --list`). `Taskfile.yaml` is
old. Do not use it.

## Kubernetes conventions

- An app is a Flux Kustomization in `ks.yaml`, with an app-template
  HelmRelease and an `OCIRepository` in `app/`. Copy a reference app from
  the `add-app` skill. Do not invent a new layout. The `add-app` skill gives the procedure.
- `ks.yaml` sets `spec.targetNamespace`. The namespace `kustomization.yaml`
  sets the namespace of the Flux Kustomizations. Do not add
  `metadata.namespace` to the resources of an app.
- Each namespace `kustomization.yaml` adds the `flux-alerts` component, and
  each one except `openebs` adds the `sops` component. Add both to a new
  namespace. Each `namespace.yaml` has `kustomize.toolkit.fluxcd.io/prune:
  disabled`, so that a mistake in Flux cannot delete a namespace. Keep it.
- `ks.yaml` reads `postBuild.substituteFrom: cluster-secrets`. That Secret
  gives `${SECRET_DOMAIN}` and `${TIMEZONE}`. Write a hostname as
  `<app>.${SECRET_DOMAIN}`.
- An app with state uses the `volsync` component and depends on
  `rook-ceph-cluster` (namespace `rook-ceph`). The variables of the component
  are `APP`, `VOLSYNC_CLAIM` and `VOLSYNC_CAPACITY`. The storage class is
  `ceph-block`.
- A database is in the shared CloudNativePG cluster `postgres16`. A file in
  `kubernetes/apps/database/cloudnative-pg/cluster/` holds its `Database` and
  the ExternalSecret of its password. The role is in `managed.roles` of
  `cluster16.yaml`. An app that needs Postgres depends on
  `cloudnative-pg-cluster` (namespace `database`).
- The secret store is the `ClusterSecretStore` named `onepassword`. Other
  home-ops repositories call it `onepassword-connect`. Do not copy that name.
- The gateways are `envoy-internal` (home network only) and `envoy-external`
  (internet, through Cloudflare), in the namespace `network`, with
  `sectionName: https`. Use `envoy-internal` unless the user asks for a
  public app.
- An MCP server for agents is a `LiteLLMMCPServer` in `kubernetes/apps/ai/`.
  The LiteLLM gateway serves it to the harnesses. See `docs/ai.md`.
- Add the annotation `reloader.stakater.com/auto: "true"` to a controller
  that reads a Secret or a ConfigMap. Without it, a change does not restart
  the pod.
- Write a version from the repository or from the upstream release. Do not
  write a version from memory. Renovate updates the versions after the merge.
- Follow the key order of `.github/instructions/helmrelease.instructions.md`
  and `sorting.instructions.md`. Do not sort lines that a change does not
  touch.

## Docker hosts

- doco-cd deploys a stack from `main` up to 30 minutes after a merge. The
  `add-host-stack` skill gives the rules. Read `hosts/<host>/README.md`
  before a change on a host.
- The `.env` files on the host hold the values of the variables. A compose
  file in git holds `${VARIABLE}` only. `hosts/ai/env-from-1password.sh`
  writes the `.env` files.

## Secrets and safety

- Do not commit a credential, a resolved secret, a kubeconfig, `talosconfig`
  or `age.key`. An app gets its secrets from an ExternalSecret that reads
  1Password. SOPS encrypts only `kubernetes/components/sops/cluster-secrets.sops.yaml`.
- A merge to `main` is a live change. A GitHub webhook starts Flux, so Flux
  applies a change in `kubernetes/` within minutes, and doco-cd applies a change in `hosts/` within 30 minutes.
  Examine the rendered result and its effect, not only the diff.
- An edit in the repository does not give you permission for a live change.
  Do not run `kubectl apply`, `kubectl delete`, `flux reconcile`,
  `flux suspend`, `talosctl` or a `just` recipe that changes the cluster,
  unless the user asks for that operation.
- These changes can lose data or stop a service. Before you make one, find
  each consumer and tell the user:
  - a change to a PVC, a storage class, or the `volsync` component;
  - a change to `bootstrap`, `externalClusters` or the object store of the
    `postgres16` cluster, or a change to `managed.roles`;
  - a rename of an app, a Kustomization, a HelmRelease or a PVC;
  - a change to `prune`, `suspend`, or to the namespace annotation;
  - the rename or removal of a stack folder or a `.doco-cd.*.yml` document.

## Validation

There is no `check` command in this repository: its shell is a Nix flake, not
devenv. Use these commands, and tell the user which ones ran.

```sh
kustomize build kubernetes/apps/<namespace>/<app>/app   # ${VARS} stay literal
kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://k8s-schemas.home-operations.com/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  <files>
docker compose -f hosts/<host>/stacks/<stack>/compose.yaml config --quiet
```

CI runs `flux-local test`, `flux-local diff`, yamllint, markdownlint and
actionlint on each PR. The flux-local diff is the rendered change. Read it
before you merge.

## Task guidance

Read the matching skill before you do these tasks:

| Task | Skill |
| --- | --- |
| Add an app to the cluster | `.claude/skills/add-app/SKILL.md` |
| Add or change a stack on a Docker host | `.claude/skills/add-host-stack/SKILL.md` |
| Merge the Renovate PRs | `.claude/skills/renovate-merge/SKILL.md` (only when the user asks) |
