# Hermes

Hermes Agent runs one container with two interfaces on one persistent profile:

- The Webapp: `https://hermes.<domain>` (gateway port 9120).
- The Dashboard: `https://hermes-dash.<domain>` (port 9119).

Both routes are on `envoy-internal`. This app comes from
`bjw-s-labs/home-ops` (`kubernetes/apps/ai/hermes`). It uses Authentik in
place of Kanidm, LiteLLM in place of agentgateway, GitHub in place of
Forgejo, and `volsync` in place of kopiur.

## Sign-in

The Authentik provider `hermes` (`selfhosted/authentik/app/blueprints/oidc.yaml`)
is a confidential client with PKCE. Only `authentik Admins` can sign in.
Each user that signs in gets full agent access, which includes a shell.

## The 1Password item `hermes`

| Field | Use |
| --- | --- |
| `API_SERVER_KEY` | The key of the Hermes API server |
| `OIDC_CLIENT_SECRET` | The secret of the Authentik client. Authentik reads the same field. |
| `LITELLM_API_KEY` | A LiteLLM virtual key for Hermes, mounted at `/mnt/secrets/litellm/key` |
| `GITHUB_TOKEN` | The fine-grained token of the organization `jaimeagents`, given to the agent as `GH_TOKEN` and `GITHUB_TOKEN` |
| `GITHUB_TOKEN_PERSONAL` | The fine-grained token of the account `jaimemachadoneto` (selected repositories only). Only the sandboxes read it (see the section GitHub) |
| `CLAUDE_CODE_OAUTH_TOKEN` | The token of `claude setup-token` for the Claude Pro subscription, mounted at `/mnt/secrets/claude/token` |
| `CLAUDE_CODE_OAUTH_TOKEN valid until` | The end date of the token. A Google Calendar event gives a warning 2 weeks before this date. |
| `CLAUDE_CODE_OAUTH_TOKEN_2` | The token of the second Claude subscription, mounted at `/mnt/secrets/claude/token-2` |
| `CLAUDE_CODE_OAUTH_TOKEN_2 valid until` | The end date of the second token, with its own Google Calendar event |
| `HERMES_STATE_GITHUB_TOKEN` | A fine-grained token for `jaimemachadoneto/hermes-state` only, read by the container `state-sync` |

Make the item before the merge. The Authentik ExternalSecret also reads it,
and fails when the item does not exist.

## GitHub

The Hermes pod has `GH_TOKEN` and `GITHUB_TOKEN` (the `jaimeagents`
token) for the features of Hermes itself: the Skills Hub, its own git clones, the Kanban
PR check and the MCP servers that it starts. It does not have
`GITHUB_TOKEN_PERSONAL`. `app/resources/gitconfig` is the git system
configuration of the pod (`GIT_CONFIG_SYSTEM`). Its one helper gives
`GITHUB_TOKEN` to git for each repository on GitHub.

A sandbox gets the three tokens from its own Secret. The ExternalSecret
`hermes-sandbox-default` in `hermes-sandbox` writes them from this item.
The plugin mounts the Secret of the Hermes profile at
`/run/secrets/github/`. git uses `GITHUB_TOKEN_PERSONAL` for
`https://github.com/jaimemachadoneto/...` and `GITHUB_TOKEN` for each other
repository. `gh` reads `GH_TOKEN`. For a repository of `jaimemachadoneto`,
run `GH_TOKEN=$GITHUB_TOKEN_PERSONAL gh ...`.

## Configuration

`app/resources/config.yaml` is a read-only overlay at
`/etc/hermes/config.yaml`. Its values have priority over the settings of a
profile. The profiles, `.env` and `SOUL.md` are on the PVC.

Hermes reads the secret sources and the model provider from the
`config.yaml` of each profile only. Do not put them in the overlay: a save in
the Dashboard then removes them from the profile. On a new volume, merge this
into `/opt/data/config.yaml` after the first start. The other profiles are
copies of `default`. `app/resources/profiles.sh` sets the secret command and
the model of each profile (see "Profiles from git").

```yaml
model:
  base_url: http://litellm.ai.svc.cluster.local:4000/v1
  provider: litellm

providers:
  litellm:
    api: http://litellm.ai.svc.cluster.local:4000/v1
    discover_models: true
    key_env: LITELLM_API_KEY
    name: LiteLLM

secrets:
  command:
    enabled: true
    command: |
      set -eu
      printf 'LITELLM_API_KEY='
      /bin/cat /mnt/secrets/litellm/key
      if [ -r /mnt/secrets/claude/token ]; then
        printf '\nCLAUDE_CODE_OAUTH_TOKEN='
        /bin/cat /mnt/secrets/claude/token
      fi
      printf '\n'
    helper_timeout_seconds: 3
    override_existing: true
```

Restart the gateway after the change. To give Hermes the MCP servers, add
`http://litellm.ai.svc.cluster.local:4000/mcp` as an MCP server in the
Dashboard with the same key.

## Claude Pro subscription

Hermes uses the Claude Pro subscription through the plugin
`claude-subscription-directsdk` (ADR 0005 and ADR 0010 in `hermes-k8s`). For
each turn, the plugin starts the `claude` CLI in the Hermes pod. Hermes runs the
tool calls in the sandbox. The sandbox has no token.

The token is a file, not an environment variable. The gateway serves each
profile through `gateway.multiplex_profiles`. In that mode the plugin does not
read the token from the process environment. The plugin reads the token from
the secrets of the profile. The secret command above gives the token to the profile from
`/mnt/secrets/claude/token`. The Secret `hermes-claude` holds that file.
Only the container `app` mounts it.

`CLAUDE_CONFIG_DIR` is `/opt/data/.claude` on the volume.

### Steps for the user

1. On a machine with `claude`, run `claude setup-token`. Do not run
   `claude auth login` in the pod.
2. In the 1Password item `hermes`, add the field `CLAUDE_CODE_OAUTH_TOKEN` with
   the token. Add the field `CLAUDE_CODE_OAUTH_TOKEN valid until` with the end
   date. Do this before the merge. The ExternalSecret `hermes-claude` fails
   until the field exists, and the pod then does not start.
3. In the Anthropic account, turn extra usage off. This account setting stops
   overage. The plugin cannot stop it (ADR 0010).
4. Add a Google Calendar event 2 weeks before the end date. Make a new token
   in that week.
5. Restart the gateway: `kubectl -n ai rollout restart deploy/hermes`. Restart
   it also after each new token, because the gateway reads the token once.

The setting `extra_usage` is in the overlay (`app/resources/config.yaml`). It
is a rule of the cluster, not a preference. `notify` is also the default value
of the plugin. The overlay pins the value, so a save in the Dashboard cannot
change it. The container `dashboard` has no token file, so the secret command
skips the token there.

### Two Claude subscriptions

The Secret `hermes-claude` holds two tokens: `token` (account 1) and
`token-2` (account 2). Both files are in the container `app`, so a profile
can read the token of the other account: the split is for the plan limits,
not a security boundary. Each profile selects one token in its own secret
command, and each account has its own `claude_config_dir`, so that the two
accounts do not share the login state of `claude`. `app/resources/profiles.sh`
sets both at each start.

Add both fields of the second token to the 1Password item before the merge.
Until the field `CLAUDE_CODE_OAUTH_TOKEN_2` exists, the ExternalSecret
`hermes-claude` reports an error and the Secret keeps only `token`. Turn extra
usage off in the second Anthropic account too.

When a plan limit is used up, Anthropic refuses the turn with a 429 and the
time of the reset. Hermes then uses the LiteLLM fallback until that time.

## Profiles from git

The init container `profiles` runs `app/resources/profiles.sh` before each
start. The script has one line for each profile:

| Profile | Persona | Model | Claude account |
| --- | --- | --- | --- |
| `default` | Chief of staff | `opus` | 1 |
| `dev` | Software engineer | `opus` | 2 |
| `infra` | Cluster and network (read-only). Subagents use LiteLLM, by task (see "Subagent tiers") | `opus` | 1 |
| `research` | Research and lessons for Jaime | LiteLLM `opr-free-strong` | none |
| `house` | Home Assistant | LiteLLM | none |
| `kid` | School mail and portal of the kids | LiteLLM | none |

The script does two different things:

- At each start, it sets the keys that point at files of the cluster: the
  secret command, `claude_config_dir`, a copy of the Claude plugin, and the
  memini namespace.
- Only once, it seeds the persona: it creates the profile, copies
  `app/resources/personas/soul-<name>.md` to `SOUL.md`, and sets the model,
  the fallback, the description and the `x-mcp-servers` header. Then it
  writes the marker file `.seeded-from-git` in the profile.

After the seed, the app owns the persona. A change in the Dashboard stays
after a redeploy. A change to a seed file in git has no effect on a seeded
profile. To seed a profile again, delete its `.seeded-from-git` and restart.

The Claude plugin is in the wrong directory of the `hermes-k8s` image:
Hermes reads a bundled model provider only from `model-providers/`. The
script therefore copies the plugin into the `plugins/` directory of each
profile with a Claude account, and makes the copy writable: Hermes cannot
stage a read-only copy from the Nix store. Remove the copy when `hermes-k8s`
fixes the image.

The init container `fix-owner` runs first. It gives the root directory of
the volume back to uid 10000. A node restart or a restore can leave it
owned by root, and the gateway then refuses to start.

### Subagent tiers

`infra` plans on `opus` and gives the work to subagents. The delegation backend
`task-tiers` (`app/resources/task-tiers/`) adds the parameter `tier` to each
subagent task, so the orchestrator selects the model from the task:

| Tier | LiteLLM model | Use |
| --- | --- | --- |
| `light` | `opr-free-light` | One read or one query |
| `standard` (default) | `opr-free-strong` | A diagnosis with several steps |
| `strong` | `opr-free-strong` | A long analysis, when time is not important |

The tiers are in `delegation.backends.task-tiers` of the profile, seeded once.
`profiles.sh` copies the plugin at each start and sets `plugins.enabled`,
because `hermes plugins enable` fails in this image (it reads `uv.lock`).

## Memory of the profiles

Each profile has two memories:

- The memory of Hermes: `memories/` and `skills/` in the profile. Hermes
  writes them itself. `profiles.sh` never changes them.
- memini, through the LiteLLM server `memini_hermes`
  (`kubernetes/apps/ai/memini-mcp`). At each start, `profiles.sh` sets the
  header `X-Memini-Namespace: hermes/<profile>`. memini then reads
  `hermes/<profile>`, `hermes` and `personal/jaime`.

The SOUL of each profile tells it to keep its working habits in the memory of
Hermes and the facts in memini.

`memini_hermes` lets the caller select the namespace. Give only the Hermes key
access to it in the LiteLLM UI.

The namespaces keep the memories in order. They are not a security boundary:
a profile can send the namespace of another profile, or `personal/jaime`. All
profiles run in one container with one LiteLLM key, so a key for each profile
does not stop this either.

## Snapshot of the configuration

The container `state-sync` runs `app/resources/state-sync.sh`. Each hour it
copies the text files of each profile to the private repository
`jaimemachadoneto/hermes-state`: `config.yaml`, `SOUL.md`, `memories/`,
`skills/` and `cron/jobs.json`. It never copies `.env`, `auth.json` or a
database. When the change has a string like a key, it pushes nothing and
writes an error to its log.

The snapshot is a view with history. Nothing reads it back into Hermes. The
full backup of the volume is volsync.

`state-sync` pushes with the 1Password field `HERMES_STATE_GITHUB_TOKEN`, a
fine-grained token for `jaimemachadoneto/hermes-state` only, with the
permission "Contents: read and write". The Secret `hermes-state-sync` holds
it, and only this container mounts it. The agent containers do not have it.

The agent can write on the volume, so the script copies no symbolic link, no
`.git` directory and no file larger than 1 MiB. The secret scan also reads
binary files.

## Sandboxes

The pod runs the Hermes image of the repository `hermes-k8s`. The image is
private on ghcr.io. The pod pulls it with the Secret `ghcr-pull`. The field
`pat_ghcr_pull` of the 1Password item `Github` gives the token.

The image has no s6. The HelmRelease therefore has two containers. The
container `app` runs `hermes gateway run` with the Webapp. The container
`dashboard` runs `hermes dashboard` on port 9119.

`terminal.backend` is `k8s_sandbox`. Each session runs its shell in a Sandbox
in the namespace `hermes-sandbox`. The pod uses the account
`hermes-sandbox-client` and its mounted token. The Role is in
`kubernetes/apps/hermes-sandbox/sandbox-tenant`. `HERMES_K8S_SANDBOX_IMAGE`
gives the sandbox image, pinned by digest. To use a new sandbox image, change
the digest in `HERMES_K8S_SANDBOX_IMAGE` in `helmrelease.yaml`.

The sandbox working directory is `/workspace`. The gateway checks that this
path exists in the pod of the gateway. The container `app` mounts an empty
directory there. No command runs in that directory.

## Rollback

Revert the PR. Flux then removes the app. A revert does not undo a database
migration on the PVC. To go back to an older image, restore the volsync
backup of the PVC first. To roll back to the upstream image, also restore the old
`config.yaml` overlay: `terminal.backend: local`, `cwd: /opt/data/workspace`
and the old `env_passthrough` list.
