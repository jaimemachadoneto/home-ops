# AI: LiteLLM gateway and MCP servers

Everything is in the `ai` namespace (`kubernetes/apps/ai/`), run by the
LiteLLM operator.

| Piece | What it is |
| --- | --- |
| `litellm` | One OpenAI-compatible API for every model, and one **MCP gateway** for every MCP server: `https://litellm.${SECRET_DOMAIN}` (envoy-internal, LAN only) |
| Models | `deepseek/deepseek-chat` (DeepSeek API), `ollama/local` (`qwen3:8b` on the Ollama host `ai.local.jaimenet.com`) |
| MCP servers | `ha_mcp` (Home Assistant), `context7` (library docs), `web_search` (SearXNG), `outlook` (Outlook.com mailbox), `browser_<session>` (one per browser-sessions session, e.g. `browser_colegio`) |
| `memini` | Long-term memory API (`memini.${SECRET_DOMAIN}`); embeddings from Ollama (`qwen3-embedding:4b`), reranker in-cluster (llmkube, `qwen3-reranker-0.6b`) |

## One URL for all MCP servers

Clients (Claude Code, Open WebUI, agents) connect to the gateway once:

- URL: `https://litellm.${SECRET_DOMAIN}/mcp/`
- Header: `Authorization: Bearer <LITELLM_MASTER_KEY>` (1Password `LiteLLM`)

Tools arrive prefixed with the server alias (`outlook-…`, `ha_mcp-…`). Add a
server by adding a `LiteLLMMCPServer` (a `url` for one that already runs, a
`workload` for one the operator should run).

LiteLLM and memini are **not** behind Authentik forward auth on purpose: they
are APIs for programs, protected by their own keys. Do not add their routes to
`authentik/forward-auth/`.

## 1Password items

Each app has its own ExternalSecret; a missing item only breaks that app.

| Item | Field | Used by |
| --- | --- | --- |
| `LiteLLM` | `master_key` | gateway key for clients |
| `deepseek` | `API_KEY` | DeepSeek model |
| `Context7` | `api_key` | context7 MCP |
| `home-assistant` | `ha_mcp_token` | Home Assistant MCP (a long-lived HA token) |
| `memini` | `API_KEY` | memini |
| `browser-sessions-mcp` | one field per session, named like the session (`colegio`) | that session's bearer token, from the browser-sessions admin UI |

## Outlook MCP: one-time sign-in

`outlook-mcp` runs `ms-365-mcp-server` (preset `mail`, full access: read,
send, move, delete) in stdio mode behind supergateway, signed in once with a
device code. The token cache is on the `outlook-mcp` PVC (backed up by
VolSync) and MSAL refreshes it; sign in again only if Microsoft revokes it
(password change, ~90 days unused).

```bash
POD=$(kubectl -n ai get pods -o name | grep outlook-mcp | head -1)
kubectl -n ai exec -it "$POD" -- node /app/dist/index.js --login
# open https://microsoft.com/devicelogin, enter the code, sign in with the Outlook.com account
kubectl -n ai exec "$POD" -- node /app/dist/index.js --verify-login
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
2. 1Password item `browser-sessions-mcp`: add a field `<name>` with the token.
3. Copy the `colegio` block in `sessions.yaml`, change the three `colegio`s.

Without a LiteLLM database every gateway client can use every session (and
every other MCP server); the per-session approval switch in browser-sessions
still holds anything that sends. Per-key access needs the database (backlog).
