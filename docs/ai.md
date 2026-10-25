# AI: LiteLLM gateway and MCP servers

Everything is in the `ai` namespace (`kubernetes/apps/ai/`), run by the
LiteLLM operator.

| Piece | What it is |
| --- | --- |
| `litellm` | One OpenAI-compatible API for every model, and one **MCP gateway** for every MCP server: `https://litellm.${SECRET_DOMAIN}` (envoy-internal, LAN only; only `/mcp` is also on the internet, for claude.ai) |
| Models | `deepseek/deepseek-chat` (DeepSeek API), `ollama/local` (`qwen3:8b` on the Ollama host `ai.local.${SECRET_DOMAIN}`) |
| MCP servers | `ha_mcp` (Home Assistant), `context7` (library docs), `web_search` (SearXNG), `outlook` (Outlook.com mailbox), `browser_<session>` (one per browser-sessions session, e.g. `browser_colegio`), `memini` (agent memory, namespace `personal/jaime`) |
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
| `LiteLLM` | `salt_key` | encrypts credentials LiteLLM stores in its DB — **never change it** |
| `LiteLLM` | `oidc_client_secret` | Authentik OIDC client `litellm` (read by both apps) |
| `deepseek` | `API_KEY` | DeepSeek model |
| `Context7` | `api_key` | context7 MCP |
| `home-assistant` | `ha_mcp_token` | Home Assistant MCP (a long-lived HA token) |
| `memini` | `API_KEY` | memini |
| `browser-sessions` | one field per session, named like the session (`colegio`) | that session's bearer token, from the browser-sessions admin UI |

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
  the same key as `memini` or `outlook`. Text that the agent reads can tell
  it to read data with one tool and send it out with the other.
- The dashboard shows a key once. If it is lost, regenerate it: the
  permissions stay.

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
   an `Authorization` header must start with `Bearer `, or LiteLLM answers
   401 "Malformed API Key".
3. To stop access, delete the key in the dashboard.

From outside the range the route answers 403. If Anthropic changes the range,
update the `SecurityPolicy`.
