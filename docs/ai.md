# AI: LiteLLM gateway and MCP servers

Everything is in the `ai` namespace (`kubernetes/apps/ai/`), run by the
LiteLLM operator.

| Piece | What it is |
| --- | --- |
| `litellm` | One OpenAI-compatible API for every model, and one **MCP gateway** for every MCP server: `https://litellm.${SECRET_DOMAIN}` (envoy-internal, LAN only; only `/mcp` is also on the internet, for claude.ai) |
| Models | `deepseek/deepseek-chat` and `deepseek/deepseek-flash` (DeepSeek API), `deepseek-flash` (the same model on OpenCode Go; each provider bills its group; `opencode-go/deepseek-flash` is its new name), `ollama/local` (`qwen3:8b` on the Ollama host `ai.local.${SECRET_DOMAIN}`), `memini-llm` (the model of memini consolidation; change its `params` to use another model), `opus` / `sonnet` / `haiku` (Claude subscription with OpenCode Go fallback, see "Claude Code through LiteLLM") |
| MCP servers | `ha_mcp` (Home Assistant), `context7` (library docs), `web_search` (SearXNG), `outlook` (Outlook.com mailbox), `browser_<session>` (one per browser-sessions session, e.g. `browser_colegio`), `memini` (agent memory, namespace `personal/jaime`), `notes` (the notes vault, see `notes-mcp.md`) |
| `memini` | Long-term memory API (`memini.${SECRET_DOMAIN}`); embeddings from Ollama (`qwen3-embedding:4b`), reranker in-cluster (llmkube, `qwen3-reranker-0.6b`) |

## One URL for all MCP servers

Clients (Claude Code, agents, the claude.ai connector) connect to the
gateway once:

- URL: `https://litellm.${SECRET_DOMAIN}/mcp/`
- Header: `Authorization: Bearer <key>` or `x-litellm-api-key: <key>`, with
  the client's own virtual key (see "LiteLLM database: per-client keys").

Do not give the master key (1Password `LiteLLM`) to a client. It is for
admin work and the break-glass dashboard login.

Tools arrive prefixed with the server alias (`outlook-…`, `ha_mcp-…`). Add a
server by adding a `LiteLLMMCPServer` (a `url` for one that already runs, a
`workload` for one the operator should run).

Sign-in (SSO):

- **memini**: the web UI is behind Authentik forward auth
  (`authentik/forward-auth/ai.yaml`); `/v1/`, `/mcp` and `/healthz` skip it
  because agents use memini's own API key there (401 without it).
- **LiteLLM**: the dashboard (`/ui`) signs in with Authentik (OIDC provider
  `litellm` in `authentik/app/blueprints/oidc.yaml`); only `authentik Admins`
  may sign in and get `proxy_admin`. Break-glass: `/fallback/login` with user
  `admin` and the master key. The API and MCP gateway stay key-only (not
  forward auth): they are for programs.
- **browser-sessions**: admin UI signs in with Authentik (OIDC).

All three are in Homepage's **AI** group; LiteLLM through `services.yaml`
there, since the operator's HTTPRoute takes no annotations.

## memini through the gateway

Claude Code on the workstation calls memini directly
(`https://memini.${SECRET_DOMAIN}/mcp`, set up by `memini-agent` in
nix-config), with one namespace for each repository. Clients that cannot
reach memini directly use the gateway server `memini`
(`kubernetes/apps/ai/memini-mcp/`). The gateway sends no project, so its
static headers put every call in the namespace `personal/jaime`.

The memini web UI asks for an API key once in each browser, because memini
v0.7 has no OIDC or trusted-header login. Authentik still controls who can
open the page.

## 1Password items

Each app has its own ExternalSecret; a missing item only breaks that app.

| Item | Field | Used by |
| --- | --- | --- |
| `LiteLLM` | `master_key` | gateway key for clients (and break-glass dashboard login) |
| `LiteLLM` | `db_password` | its Postgres role `litellm` (CNPG `managed.roles`, database `litellm`) |
| `LiteLLM` | `grafana_db_password` | Grafana's read-only Postgres role `litellm_grafana` for the cost dashboard |
| `LiteLLM` | `salt_key` | encrypts credentials LiteLLM stores in its DB — **never change it** |
| `LiteLLM` | `oidc_client_secret` | Authentik OIDC client `litellm` (read by both apps) |
| `deepseek` | `API_KEY` | DeepSeek model |
| `Context7` | `api_key` | context7 MCP |
| `home-assistant` | `ha_mcp_token` | Home Assistant MCP (a long-lived HA token) |
| `memini` | `API_KEY` | memini |
| `browser-sessions` | one field per session, named like the session (`colegio`) | that session's bearer token, from the browser-sessions admin UI |
| `opencode-go` | `credential` | the `go-*` models and go-catalog-sync (OpenCode console API key) |
| `mqtt` | `mqtt_username`, `mqtt_password` | go-catalog-sync (the login of ha-status) |

## Outlook MCP: one-time sign-in

`outlook-mcp` runs `ms-365-mcp-server` (preset `mail`, full access: read,
send, move, delete) in stdio mode behind supergateway, signed in once with a
device code. The token cache is on the `outlook-mcp` PVC (backed up by
VolSync) and MSAL refreshes it; sign in again only if Microsoft revokes it
(password change, ~90 days unused).

```bash
POD=$(kubectl -n ai get pods -o name | grep outlook-mcp | head -1)
kubectl -n ai exec -it "$POD" -- ms-365-mcp-server --login
# open https://microsoft.com/devicelogin, enter the code, sign in with the Outlook.com account
kubectl -n ai exec "$POD" -- ms-365-mcp-server --verify-login
```

It uses the project's built-in Entra app. To use your own: register an app in
Entra (personal accounts allowed, public client, Mail.ReadWrite + Mail.Send),
put its ID in an ExternalSecret and set `MS365_MCP_CLIENT_ID`, then sign in
again. To make it read-only, add `--read-only` to the server command in
`outlook-mcp/app/mcpserver.yaml`.

## Outlook MCP: an update needs a follow-up command

Each change to `outlook-mcp` (for example a Renovate image update) stops in
the rollout. The new pod stays at `Init:0/1`, and Flux still shows Ready.
The cause: litellm-operator sets no Deployment strategy, so the default
`RollingUpdate` keeps the old pod. The old pod holds the RWO `outlook-mcp`
PVC, and the new pod on a different node cannot attach it.

After the merge, scale the old ReplicaSets to 0. Do not delete the old pod:
its ReplicaSet makes a new pod that can attach the volume first.

```bash
REV=$(kubectl -n ai get deploy outlook-mcp -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')
kubectl -n ai get rs -l app.kubernetes.io/name=outlook-mcp \
  -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.annotations.deployment\.kubernetes\.io/revision}{"\n"}{end}' |
  awk -v rev="$REV" '$2 != rev {print $1}' | xargs kubectl -n ai scale rs --replicas=0
kubectl -n ai rollout status deploy/outlook-mcp
kubectl -n ai exec deploy/outlook-mcp -c mcp -- ms-365-mcp-server --verify-login
```

The mail tools are not available for a minute or two. Remove this section
when litellm-operator has a `strategy` field and `mcpserver.yaml` sets
`strategy: {type: Recreate}`.

## browser-sessions sessions

Each session has its own MCP URL and token by design, so each is its own MCP
server in the gateway (`ai/browser-sessions-mcp/app/sessions.yaml`). To add a
session `<name>`:

1. Create it in `https://bwsessions.${SECRET_DOMAIN}/admin`, copy the token.
2. 1Password item `browser-sessions`: add a field `<name>` with the token.
3. Add `<name>` to `browser-sessions-mcp/app/externalsecret.yaml` and copy the
   `colegio` block in `sessions.yaml` with the names changed.

A virtual key reaches only the MCP servers it lists, so give a session only
to the key of the client that needs it. The per-session approval switch in
browser-sessions still holds anything that sends.

## Claude Code through LiteLLM, with OpenCode Go fallback

Claude Code uses the Claude subscription through LiteLLM. When the
subscription gets to its usage limit, LiteLLM sends the request to an
OpenCode Go model of the same tier.

| Part | File |
| --- | --- |
| Model groups `opus`, `sonnet`, `haiku` (`anthropic/claude-*-5-5`, no key) | `litellm/app/models/claude-*.yaml` |
| Fallback chains, routing strategy, retries, cooldown, timeout | the LiteLLM UI (Router Settings). The database keeps them. Do not set these keys in `routerSettings`: then the file owns them and LiteLLM refuses a change in the UI. |
| Redis of the router | `litellm/app/litellmproxy.yaml`, `routerSettings` |
| Model group `deepseek-flash` (`opencode_go/deepseek-v4.1-flash` with a fixed `x-opencode-session` header; UI fallback to `opr/deepseek-v4.1-flash`), used by the `claude-deepseek` alias of nix-config; OpenCode Go bills it | `litellm/app/models/deepseek-flash.yaml` |
| Model group `opencode-go/deepseek-flash`, the new name of the same group. The two groups exist during the change; remove `deepseek-flash` when every client uses this name | `litellm/app/models/opencode-go-deepseek-flash.yaml` |
| Model group `deepseek/deepseek-flash` (`deepseek/deepseek-flash` on `api.deepseek.com`), which DeepSeek bills | `litellm/app/models/deepseek-flash-api.yaml` |
| `go-*` models (`opencode_go/…`) and `opr/*` models (`openrouter/…`) | managed by go-catalog-sync via LiteLLM admin API — no CRDs |
| Daily sync of Go and OpenRouter models and prices | `go-catalog-sync/` |

- `opencode-go/deepseek-flash` (old name `deepseek-flash`) and
  `deepseek/deepseek-flash` serve the same model, but each provider bills its
  own group. DeepSeek bills at peak prices from 01:00 to 04:00 and 06:00 to
  10:00 UTC, Monday to Friday, but not on Chinese public holidays. LiteLLM
  cannot follow those holidays, so it records a peak price also on a holiday.
- The `anthropic/` models have no key. LiteLLM forwards the OAuth token
  (`sk-ant-oat…`) that Claude Code sends. LiteLLM v1.106.5 forwards this
  token to each `anthropic/` model, also with a different `api_base`. Thus
  never point an `anthropic/` model at a provider that is not Anthropic.
- No LiteLLM release has the `opencode_go/` provider yet, so the proxy runs
  `main-latest` at a fixed digest. When a release has it, go back to a
  version tag.
- The router settings in the UI are `num_retries: 0`, `allowed_fails: 1`
  and `cooldown_time: 300` for all models. One failure of a model group
  sends the next requests to its fallbacks for 5 minutes. If you clear them,
  LiteLLM uses its defaults and retries the Claude subscription first.
- Fallbacks catch all errors, also 401. If the Claude login expires,
  all requests go to Go and nothing tells you. The spend logs show
  `attempted_fallbacks`. To correct it, run `/login` in Claude Code.
- Do not add `muse-spark-*` or `iceman-contributor-free` models: they train
  on prompts. Do not set `forward_client_headers_to_llm_api`.

### Claude Code settings

Make a virtual key that can call `opus`, `sonnet`, `haiku` and every `go-*`
model group. If the key cannot call a `go-*` group, LiteLLM skips that
fallback. Then set this in `~/.claude/settings.json` (from `~/nix-config`):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://litellm.${SECRET_DOMAIN}",
    "ANTHROPIC_CUSTOM_HEADERS": "x-litellm-api-key: <virtual key>",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "opus",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "sonnet",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "haiku"
  }
}
```

Do not set `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or `apiKeyHelper`.
Sign in with "Claude account with subscription".

### go-catalog-sync

A CronJob in `ai`, every day at 07:00 Europe/Madrid. The code and the
image are in [go-catalog-sync](https://github.com/jaimemachadoneto/go-catalog-sync).
It writes to the LiteLLM database through the admin API:

1. It fetches the Go model list (with the `opencode-go` API key) and the
   OpenRouter public catalog.
2. It lists existing managed models from LiteLLM (`/model/list`).
3. It creates, updates and deletes models via `/model/new`, `/model/update`
   and `/model/delete`. A model you disabled in the dashboard stays disabled
   through updates; stale models are removed.
4. It publishes status and events to MQTT for both `homelab/opencode-go` and
   `homelab/openrouter`. Home Assistant gets the devices through MQTT
   discovery.

**Go models:** `GO_MODEL_IDS` (space-separated Go model IDs in the
helmrelease) controls which Go models are synced. Model name `go-<id>`,
params `opencode_go/<id>`, API key from the `opencode-go` secret.

**OpenRouter models:** `OPENROUTER_PROVIDERS` (space-separated vendor
prefixes) filters the OpenRouter catalog, plus all `:free` models. Model
name `opr/<model>`, params `openrouter/<vendor>/<model>`, API key from the
`litellm` secret.

If a Go price changes by more than 3 times, the sync keeps the old price
and sends `price_change_suspicious`. To add a Go model, add its id to
`GO_MODEL_IDS` in the helmrelease.

Run it now: `kubectl -n ai create job --from=cronjob/go-catalog-sync go-sync-test`.

The phone notification is a Home Assistant autom tion. Change the
`notify.mobile_app_*` action to your phone:

```yaml
alias: OpenCode Go catalog change
mode: queued
triggers:
  - trigger: mqtt
    topic: homelab/opencode-go/event
autions:
  - action: notify.mobile_app_YOUR_PHONE
    daa:
      title: "OpenCode Go: {{ trigger.payload_json.event_type | replace('_', ' ') }}"
      message: "{{ trigger.payload_json.message }}"
      data:
        tag: opencode-go-{{ trigger.payload_json.event_type }}
```

Add a second automation for the OpenRouter topic
`homelab/openrouter/event` with tag `openrouter-…`.

### Make sure that it works

1. Call each `go-*` model through LiteLLM. Each one must give 200.
2. Make a temporary model group to Anthropic with a key that is not
   correct, with a fallback to a `go-*` model. Call it and look for the
   response header `x-litellm-attempted-fallbacks`. Then remove the group.
   (Since v1.85.0 the proxy removes `mock_testing_fallbacks` from requests.)
3. In the LiteLLM logs, a request to Go must not have an `sk-ant-oat`
   `Authorization` header.

## LiteLLM database: per-client keys

LiteLLM keeps keys, users, teams and spend logs in database `litellm` on
`postgres16` (role capped at 40 connections, pool 10). With it, give each
client its own key instead of the master key, limited to the models and MCP
servers it needs: dashboard → Virtual Keys → Create, and under MCP choose the
servers and tools (e.g. only `web_search` and `context7` for a coding agent,
never `outlook` unless it needs mail).

- An empty model list gives the key **all** models. For a key without models,
  set the model `no-default-models`.
- Do not put a tool that fetches any URL (`web_search` has `web_url_read`) in
  the same key as `memini`, `notes` or `outlook`. Text that the agent reads can tell
  it to read data with one tool and send it out with the other.
- The dashboard shows a key once. If it is lost, regenerate it: the
  permissions stay.

## LiteLLM cost dashboard

The **AI / LiteLLM Cost** dashboard reads spend history from Postgres, not
Prometheus (which keeps only seven days). The traffic, fallback and latency
panels still use Prometheus. Costs are LiteLLM's estimates: for the Claude
subscription and OpenCode Go they are list-price equivalents, not invoices.

Before reconciling Grafana, generate a password in 1Password item `LiteLLM`,
field `grafana_db_password`. Two ExternalSecrets use it: the CNPG role's
`litellm-grafana-db-credentials` and Grafana's `grafana-litellm-db`.

After CNPG has created the role, create the restricted view and grant once.
The view deliberately omits API keys, prompts, responses and request metadata;
Grafana has SELECT only on this view, not on any LiteLLM table.

```bash
PRIMARY=$(kubectl -n database get pods -l cnpg.io/cluster=postgres16,role=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n database exec -i "$PRIMARY" -c postgres -- psql -v ON_ERROR_STOP=1 -U postgres -d litellm <<'SQL'
BEGIN;
CREATE OR REPLACE VIEW public.litellm_grafana_spend
WITH (security_invoker = false) AS
SELECT
  "startTime" AS time,
  custom_llm_provider AS provider,
  model,
  model_group AS requested_model,
  COALESCE(metadata->>'user_api_key_alias', 'None') AS api_key_alias,
  spend,
  total_tokens,
  prompt_tokens,
  completion_tokens
FROM public."LiteLLM_SpendLogs"
WHERE custom_llm_provider IS NOT NULL;
GRANT CONNECT ON DATABASE litellm TO litellm_grafana;
GRANT USAGE ON SCHEMA public TO litellm_grafana;
GRANT SELECT ON public.litellm_grafana_spend TO litellm_grafana;
COMMIT;
SQL
```

There is no spend-log cleanup configured; the history grows until LiteLLM's
`maximum_spend_logs_retention_period` is set. Re-run the SQL only if the
`litellm` database is recreated, or to change the view.

## claude.ai connector

claude.ai calls a custom connector from Anthropic's cloud, so the LAN-only
gateway cannot serve it, and a VPN does not help. `litellm/app/httproute-external.yaml`
puts only `/mcp` on `envoy-external` (Cloudflare tunnel). Its `SecurityPolicy`
accepts only Anthropic's outbound range `160.79.104.0/21`. The dashboard, the
admin API and the models stay on the LAN.

The connector sends a virtual key, never the master key:

1. Dashboard → Virtual Keys → Create: name `claude-ai`, model
   `no-default-models`, and under MCP only `context7` and `memini`. An empty
   model list gives the key all models. Claude on claude.ai reads web pages
   and files, and text in them can tell it to call a tool. So do not give it
   `outlook` or a browser session. Also do not give it `web_search`:
   `web_url_read` fetches any URL, and with `memini` that can send memories
   out. claude.ai has its own web search and fetch.
2. claude.ai → Customize → Connectors → Add → Add custom connector: URL
   `https://litellm.${SECRET_DOMAIN}/mcp/`, Authentication **No sign-in**,
   and under Request headers `x-litellm-api-key` with the key. The value of
   an `Authorization` header must start with `Bearer `, or LiteLLM answers <!-- markdownlint-disable-line MD038 -->
   401 "Malformed API Key".
3. To stop access, delete the key in the dashboard.

From outside the range the route answers 403. If Anthropic changes the range,
update the `SecurityPolicy`. The route has the annotation
`home-ops.io/lan-dns: skip`, so the UniFi DNS has only the internal address of
`litellm`: with both addresses, LAN clients got that 403 at random.

### The public record of litellm and external-dns 1.23.0

From 2026-10-29 to 2026-10-30 the connector did not work: Cloudflare had no
record for `litellm.${SECRET_DOMAIN}` (NXDOMAIN).

- Cause: the external-dns chart 1.23.0 (app v0.23.0, #262). The Cloudflare
  instance made `litellm` an A record to the private IP of envoy-external,
  `10.30.50.200`, not a CNAME to `ingress-ext`. Cloudflare refuses a proxied
  record to a private IP (error 9003). The failed create is a soft error for
  the full zone, so no other public record changed either.
- The annotation `external-dns.alpha.kubernetes.io/target` on the route did
  not fix it. The route keeps it, as the route of Authentik does.
- Fix: the Cloudflare instance is back on 1.20.0
  (`external-dns/cloudflare/ocirepository.yaml`). It made the CNAME at its
  first sync. UniFi and Pi-hole stay on 1.23.0.
- There is no Renovate hold, so each new version comes as a PR. Do not
  merge 1.23.0 again. Merge a newer version only as a test: after Flux
  applies it, watch the log of the Cloudflare instance for one minute. If
  error 9003 comes back, revert the PR. To find the cause, set `logLevel:
  debug` in `external-dns/cloudflare/helmrelease.yaml`.

To check: `dig litellm.${SECRET_DOMAIN} @1.1.1.1` gives Cloudflare addresses,
and `kubectl -n network logs deploy/externaldns-cloudflare` has no error 9003.
