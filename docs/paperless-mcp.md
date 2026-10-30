# Plan: a Paperless MCP server, for Claude Code and claude.ai

Status: plan only (2026-10-30). Nothing is deployed. Hostnames follow this
repo (`${SECRET_DOMAIN}`).

## Goal

Agents work with my Paperless documents through one MCP server:

- **Search and read:** find a document by its text, tags, correspondent or
  date, and read its content and metadata.
- **Organize:** set tags, correspondents, document types and custom fields,
  and add notes to a document.
- **Upload:** add a new document, from Claude Code and also from claude.ai
  (web and phone), where Claude cannot send the bytes of a file to a tool.

## What exists today

- Paperless-ngx 3.3.4 in `selfhosted/paperless/app/`. It has only an
  internal route (`paperless.${SECRET_DOMAIN}` on envoy-internal), the
  Service `paperless.selfhosted.svc.cluster.local:8000`, and Authentik OIDC
  logins. It consumes files from `/data/nas/incoming`.
- `paperless-ai` and `paperless-gpt` already use the Paperless API from the
  cluster (`selfhosted/paperless/ai/`, `selfhosted/paperless/gpt/`).
- The LiteLLM MCP gateway (`docs/ai.md`). Claude Code reaches it on the LAN.
  claude.ai reaches only its `/mcp` path, through `litellm-external`
  (envoy-external, Anthropic's IP range only), with the virtual key
  `claude-ai`.
- The notes MCP server (`docs/notes-mcp.md`) already does the upload-link
  pattern for the vault (`request_upload`, `check_upload`). Its links are on
  envoy-internal, so they work only on the LAN.

## Decisions

- **Server: a fork of [baruchiro/paperless-mcp](https://github.com/baruchiro/paperless-mcp)**
  (TypeScript, ISC licence, about 150 stars). It has more than 40 tools,
  `post_document` for uploads, and an HTTP mode with `POST /mcp`. In HTTP
  mode the client sends a Paperless API token in `Authorization: Bearer`,
  so the permissions of that Paperless user are the permissions of the
  agent. The server keeps no token of its own.
  - Not chosen: [barryw/PaperlessMCP](https://github.com/barryw/PaperlessMCP)
    (.NET, MIT, about 50 stars). It has good guards (a delete needs a
    confirmation, bulk edits start as a dry run) and an outbox for
    downloads. But its `/mcp` has no authentication and one server token
    for all clients, so the network policy would be its only gate.
- **One server, two ways in:** `/mcp` only through the LiteLLM gateway;
  the upload page `/upload/<token>` on its own route. The upload page
  cannot go through LiteLLM: `litellm-external` lets in only Anthropic's
  addresses, and LiteLLM proxies only MCP.
- **Paperless users decide the permissions, not the MCP server.** The server
  has no read-only mode and no tool allowlist. A dedicated Paperless user
  `mcp` gets only the permissions that the agents need. Never use the token
  of `akadmin` (a superuser; Authentik logins map to it, see
  `docs/backlog.md`).
- **Uploads go out of band.** In MCP, the model writes the arguments of a
  tool call as text. A file through `post_document` must be base64 in the
  conversation: about 1.3 million characters for a 1 MB PDF. That is too
  large for a session. claude.ai also cannot give the exact bytes of an
  attached file. So the fork adds an upload link (see phase 3).
- **Where it runs:** `selfhosted/paperless/mcp/`, next to `ai/` and `gpt/`,
  in the namespace of Paperless. The gateway entry is
  `ai/paperless-mcp/`, as for the notes server.

## Phase 1: read and organize, Claude Code only

1. In Paperless, make the user `mcp`. Give it view permission on documents,
   tags, correspondents, document types, storage paths and custom fields.
   Do not give it delete or admin permissions. Make its API token, and save
   it in 1Password, item `paperless-mcp`, field `api_token`.
2. Fork baruchiro/paperless-mcp to my GitHub account. Build its image to
   GHCR with GitHub Actions, as for the obsidian-mcp fork. Pin the image by
   digest.
3. `selfhosted/paperless/mcp/`: app-template HelmRelease, HTTP mode, port
   3000. `PAPERLESS_URL` is the internal Service. Do not set
   `PAPERLESS_API_KEY`: each request brings its token. Unset
   `PAPERLESS_MCP_UPLOAD_PATHS`, or set it to an empty directory, so
   `file_path` uploads cannot read files of the pod.
4. A CiliumNetworkPolicy, as for the notes server: ingress only from LiteLLM
   (and the kubelet probes), egress only to Paperless on port 8000 and to
   DNS.
5. `ai/paperless-mcp/`: a `LiteLLMMCPServer` `paperless`
   (`authType: bearer_token`, the token from an ExternalSecret).
6. nix-config: add `paperless` to `litellmMcpServers` of the workstation
   only. The work MacBook keeps `[ "notes" ]`.

Done when, from Claude Code on the workstation:

- a search for a word in a scanned letter finds that letter;
- the agent can read a document and its metadata;
- a write tool (a new tag) is refused by Paperless with 403, because the
  user `mcp` can only view.

Then give `mcp` change permission on documents, tags and correspondents, if
I want agents to organize. Still no delete.

## Phase 2: claude.ai

1. Decide if the key `claude-ai` gets `paperless` (see "Open questions").
   If yes, add `paperless` to the MCP servers of that key in the LiteLLM
   dashboard.
2. Test from claude.ai: a search and a read work; the server is not
   reachable from outside Anthropic's range.

The public record of `litellm` must exist for this. external-dns 1.23.0
broke it once (`docs/ai.md`, "The public record of litellm and external-dns
1.23.0").

## Phase 3: uploads through a link

Add two tools to the fork, as in the notes server:

- `request_upload(title?, tags?, correspondent?, document_type?)` makes a
  random token, keeps it with these values, and returns
  `https://paperless-upload.${SECRET_DOMAIN}/upload/<token>`.
- `check_upload(upload_id)` tells if the file arrived, and gives the task
  ID of Paperless and then the document ID.

The upload page is one small HTML form at `/upload/<token>`. It sends the
file to `POST /api/documents/post_document/` of Paperless with the stored
values, as the user `mcp`.

Rules for the upload page:

- The token is for one upload only, and it expires after 15 minutes.
- Keep the token in the URL fragment, not in the query string, as the
  notes server does, so logs and proxies do not see it.
- A size limit (for example 50 MB) and a list of permitted types (PDF and
  images).
- The route: envoy-external with Authentik forward auth in front, so an
  upload works from the phone away from home. I log in once. A token
  without an Authentik login does nothing.
- The user `mcp` needs add permission on documents for this.

Flow from claude.ai: Claude calls `request_upload` and gives me the link. I
open it on the phone and pick the file. Claude calls `check_upload` and
then sets the metadata with the normal tools.

From Claude Code there is a second way: `curl` to the Paperless API with a
local path. The file does not go through the conversation, but the machine
needs a Paperless token. The upload link works there too.

Done when:

- a PDF uploaded through the link from the phone, away from home, is in
  Paperless with the tags of `request_upload`;
- a second use of the same link is refused, and an old link is refused;
- the upload page without an Authentik login is refused.

## Open questions

- Does the key `claude-ai` get `paperless`? claude.ai reads web pages and
  files, and has its own web fetch. Text in a page or in a document can
  tell Claude to read documents and send them out. `docs/ai.md` keeps
  `outlook` and browser sessions away from that key for this reason.
  Paperless holds tax, health and bank papers. A middle way: a second
  Paperless user with view permission on only some tags, for the key
  `claude-ai`.
- Send the notes upload links through the same kind of public route? Today
  they work only on the LAN.
- Should upstream get the upload tools as a PR, so the fork can end?
- Paperless itself stays internal. Only the upload page and LiteLLM's
  `/mcp` are public.
