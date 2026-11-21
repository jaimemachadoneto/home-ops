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
| `GITHUB_TOKEN` | A GitHub token, given to the agent as `GH_TOKEN` and `GITHUB_TOKEN` |

Make the item before the merge. The Authentik ExternalSecret also reads it,
and fails when the item does not exist.

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
      printf '\n'
    helper_timeout_seconds: 3
    override_existing: true
```

Restart the gateway after the change. To give Hermes the MCP servers, add
`http://litellm.ai.svc.cluster.local:4000/mcp` as an MCP server in the
Dashboard with the same key.

## Rollback

Revert the PR. Flux then removes the app. A revert does not undo a database
migration on the PVC. To go back to an older image, restore the volsync
backup of the PVC first.
