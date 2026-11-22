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
| `GITHUB_TOKEN_PERSONAL` | The fine-grained token of the account `jaimemachadoneto` (selected repositories only) |
| `CLAUDE_CODE_OAUTH_TOKEN` | The token of `claude setup-token` for the Claude Pro subscription, mounted at `/mnt/secrets/claude/token` |
| `CLAUDE_CODE_OAUTH_TOKEN valid until` | The end date of the token. A Google Calendar event gives a warning 2 weeks before this date. |

Make the item before the merge. The Authentik ExternalSecret also reads it,
and fails when the item does not exist.

## GitHub

`app/resources/gitconfig` is the git system configuration
(`GIT_CONFIG_SYSTEM`). git uses `GITHUB_TOKEN_PERSONAL` for
`https://github.com/jaimemachadoneto/...` and `GITHUB_TOKEN` for each other
repository on GitHub. `gh` reads `GH_TOKEN` only, so it works on the
`jaimeagents` repositories. For a repository of `jaimemachadoneto`, run
`GH_TOKEN=$GITHUB_TOKEN_PERSONAL gh ...`.

## Configuration

`app/resources/config.yaml` is a read-only overlay at
`/etc/hermes/config.yaml`. Its values have priority over the settings of a
profile. The profiles, `.env` and `SOUL.md` are on the PVC.

Hermes reads the secret sources and the model provider from the
`config.yaml` of each profile only. Do not put them in the overlay: a save in
the Dashboard then removes them from the profile. Merge this into
`/opt/data/config.yaml` (or `/opt/data/profiles/<name>/config.yaml`) after
the first start. Keep the other settings of the profile.

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
5. After the merge, change the profile configuration on the volume. The
   commands follow in the next section.
6. Restart the gateway: `kubectl -n ai rollout restart deploy/hermes`. Restart
   it also after each new token, because the gateway reads the token once.

### Profile configuration on the volume

`/opt/data/config.yaml` holds the model provider, the default model, the
fallback and the secret command. The overlay does not hold them, because
Hermes reads them from the profile only. This section replaces the provider and
the secret command of the section "Configuration".

The container `dashboard` has no token file, so the secret command skips the
token there.

The setting `extra_usage` is in the overlay (`app/resources/config.yaml`). It
is a rule of the cluster, not a preference. `notify` is also the default value
of the plugin. The overlay pins the value, so a save in the Dashboard cannot
change it.

Run each command in the pod:

```sh
h() { kubectl -n ai exec -i deploy/hermes -c app -- "$@"; }

# 1. This command replaces the old secret command.
h sh -c 'hermes config set secrets.command.command "$(cat)"' <<'EOF'
set -eu
printf 'LITELLM_API_KEY='
/bin/cat /mnt/secrets/litellm/key
if [ -r /mnt/secrets/claude/token ]; then
  printf '\nCLAUDE_CODE_OAUTH_TOKEN='
  /bin/cat /mnt/secrets/claude/token
fi
printf '\n'
EOF

# 2. Set the subscription as the provider. Remove the old LiteLLM base_url.
h hermes config set model.provider claude-subscription-directsdk-experimental
h hermes config set model.default sonnet
h hermes config set model.base_url ""

# 3. Set LiteLLM as the fallback. Keep the block providers.litellm.
h hermes config set fallback_model.provider litellm
h hermes config set fallback_model.model opr/deepseek-v4.1-flash
h hermes config set fallback_model.base_url http://litellm.ai.svc.cluster.local:4000/v1
h hermes config set fallback_model.key_env LITELLM_API_KEY

# 4. Check.
h hermes fallback list
```

To go back to LiteLLM as the primary provider, set `model.provider` to
`litellm`, `model.default` to `opr/deepseek-v4.1-flash`, and `model.base_url`
to the LiteLLM URL.

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
