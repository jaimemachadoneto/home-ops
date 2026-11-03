# Plan: a Paperless MCP server, for Claude Code and claude.ai

Status: phases 1 and 2 done (2026-10-31): read-only search and read from
Claude Code on the workstation and the work MacBook, and from claude.ai (the
keys of all three allow `paperless`); a write is refused with 403. Phase 3
is done (2026-10-31): uploads through a single-use link work from `curl` and
from the phone away from home. Phase 4 adds semantic search and download
links (image `sha-8a0a66e`). See "Deploy of phase 4" for the steps and the
acceptance test. The server is the fork `jaimemachado/paperless-mcp`.
Hostnames follow this repo (`${SECRET_DOMAIN}`).

## Goal

Agents work with my Paperless documents through one MCP server:

- **Search and read:** find a document by its text, tags, correspondent or
  date, and read its content and metadata.
- **Organize:** set tags, correspondents, document types and custom fields,
  and add notes to a document.
- **Find by meaning:** find a document with words that are not in its text,
  and download its file through a single-use link.
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
  agent. The server keeps two tokens of its own: the token of
  `paperless-upload` for the upload and download links (phase 3), and the
  token of `paperless-mcp` for the sync of the search index (phase 4).
  - Not chosen: [barryw/PaperlessMCP](https://github.com/barryw/PaperlessMCP)
    (.NET, MIT, about 50 stars). It has good guards (a delete needs a
    confirmation, bulk edits start as a dry run) and an outbox for
    downloads. But its `/mcp` has no authentication and one server token
    for all clients, so the network policy would be its only gate.
- **One server, two ways in:** `/mcp` only through the LiteLLM gateway;
  the routes `/upload/<token>` and `/download/<token>` on their own public
  route. These routes cannot go through LiteLLM: `litellm-external` lets in
  only Anthropic's addresses, and LiteLLM proxies only MCP.
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

Phase 1 runs the upstream image (2.2.1, pinned by digest): the fork is needed
only for the upload tools of phase 3.

1. In Paperless, the user `paperless-mcp` in the group `mcp-read`: view
   permission on documents, tags, correspondents, document types, storage
   paths, custom fields and notes. No change, delete or admin permission.
   Paperless hides owned documents from other users, so the group also gets
   view on the existing objects, the workflow "Share new documents with
   ai-services" gives it view on each new document, and the default view
   groups of the superusers include it. Its API token goes in 1Password, item
   `Paperless`, field `paperless_mcp_api_token`. (Same pattern as the users of
   paperless-ai and paperless-gpt, group `ai-services`.)
2. `selfhosted/paperless/mcp/`: app-template HelmRelease, HTTP mode, port
   3000, user 1000, read-only root file system. `PAPERLESS_URL` is the
   internal Service. `PAPERLESS_API_KEY` is not set: each request brings its
   token. `PAPERLESS_MCP_UPLOAD_PATHS` is a directory that does not exist, so
   `file_path` uploads cannot read files of the pod.
3. A CiliumNetworkPolicy, as for the notes server: ingress only from LiteLLM
   on `/mcp` (and the kubelet probes), egress only to the Paperless web pod
   on port 8000 and to DNS.
4. `ai/paperless-mcp/`: a `LiteLLMMCPServer` `paperless`
   (`authType: bearer_token`, the token from an ExternalSecret).
5. In the LiteLLM dashboard, add the MCP server `paperless` to the key of
   the workstation.
6. nix-config: add `paperless` to `litellmMcpServers`: the default list (the
   workstation) and the work MacBook (`[ "notes" "paperless" ]`), with
   `paperless` on its key `litellm-mac` too.

Done when, from Claude Code on the workstation:

- a search for a word in a scanned letter finds that letter;
- the agent can read a document and its metadata;
- a write tool (a new tag) is refused by Paperless with 403, because the
  user `paperless-mcp` can only view.

Then give `mcp-read` change permission on documents, tags and correspondents
(and the workflow change access for it), if I want agents to organize. Still
no delete.

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

`/upload/<token>` takes the file in two ways: `GET` gives one small HTML
form (for a person on the phone), and `POST` with `multipart/form-data`
(field `file`) takes the file directly (for an agent with `curl`). Both send
it to `POST /api/documents/post_document/` of Paperless with the stored
values, as the user `paperless-upload`. An upload brings no Paperless token:
the phone and `curl` have none. So the server keeps the token of this user.
The user can only add documents (`add_document`). It can also view tags,
correspondents and document types to set them, and tasks for
`check_upload`. The read user `paperless-mcp` stays view only.

Decided (2026-10-31): the single-use link is the only gate, with no
Authentik login. A login would stop `curl` from OpenCode and Claude Code.
The worst case of a leaked link is one unwanted file in Paperless: the link
cannot read or change anything.

Rules for the upload route:

- The token is for one upload only (the first try uses it, also when it
  fails), and it expires after 15 minutes.
- The token is in the path, not in a URL fragment: `curl` does not send the
  fragment. The proxy logs can show the path, but a token in a log is
  already used or expired.
- A size limit (for example 50 MB) and a list of permitted types (PDF and
  images); anything else is refused before Paperless sees it.
- Each upload gets the tag `via-mcp`, so I can find it.
- The route: envoy-external, only the path `/upload/`, so an upload works
  away from home. `/mcp` stays behind LiteLLM.
- The new user `paperless-upload` is in the sharing workflow like the other
  users, and its token is in 1Password (item `Paperless`, field
  `paperless_upload_api_token`).

Flow from claude.ai: Claude calls `request_upload` and gives me the link. I
open it on the phone and pick the file. Claude calls `check_upload` and
then sets the metadata with the normal tools.

Flow from an agent with a shell (OpenCode, Claude Code): it calls
`request_upload`, then `curl -F file=@<path> <link>`, then `check_upload`.
The file goes from disk to Paperless and never through the conversation,
and the machine needs no Paperless token.

Done when:

- a PDF uploaded through the link from the phone, away from home, is in
  Paperless with the tags of `request_upload` and `via-mcp`;
- `curl -F file=@x.pdf <link>` from Claude Code does the same;
- a second use of the same link is refused, and an old link is refused;
- a file that is too large or of another type is refused.

## Deploy of phase 3

The fork is `jaimemachado/paperless-mcp` (`repos/paperless-mcp`), branch
`feat/upload-links`. The tools exist only when the server has
`PAPERLESS_UPLOAD_API_KEY` and `PAPERLESS_UPLOAD_PUBLIC_URL`. The links
are in memory, so a restart of the pod makes the open links not valid.
Keep one replica.

`request_upload` and `check_upload` first read `/api/tags/` with the token
of the caller, so a Bearer value that Paperless does not know gets
nothing. Do not use `/api/ui_settings/` for this check: it needs the
permission `view_uisettings`, and `mcp-read` does not have it.

The server streams each file to `/tmp` and then to Paperless. In a local
test (2026-10-31), two uploads of 50 MB at the same time added about
45 MB of memory to the server, so the limit of 256Mi stays.

Do these steps in this sequence:

1. In the fork, enable GitHub Actions. A fork starts with Actions off.
2. Merge `feat/upload-links` into `main`. `docker-publish.yml` pushes
   `ghcr.io/jaimemachado/paperless-mcp:sha-<commit>`.
3. Make the package public in GHCR, or give the cluster a pull secret.
4. In Paperless, make the tag `via-mcp` and the user `paperless-upload`.
   The user gets `add_document`, and view on tags, correspondents,
   document types and tasks. Without view on tasks, `check_upload` fails.
5. Add `paperless-upload` to the workflow "Share new documents with
   ai-services", so `paperless-mcp` can see its uploads.
6. In 1Password, put the API token of `paperless-upload` in the item
   `Paperless`, field `paperless_upload_api_token`. Do this before the
   merge in home-ops: the pod does not start without this secret.
7. In `selfhosted/paperless/mcp/helmrelease.yaml`, set the image of the
   fork, pinned by digest.
8. Merge the home-ops branch.

The route `paperless-upload.${SECRET_DOMAIN}` is on envoy-external with
the path prefix `/upload/`. The CiliumNetworkPolicy lets envoy-external
send only `GET` and `POST` to `/upload/<token>`, so `/mcp` stays behind
LiteLLM.
A BackendTrafficPolicy limits the route to 30 requests a minute, for all
clients together. Envoy refuses the next request with 429, before the
server sees it, so a refused request does not use the link. Do not turn on
the Cloudflare Bot Fight Mode or a challenge for this hostname: it stops
`curl` from the agents.

The test after the deploy (2026-10-31) passed. Through the public URL, a
PDF went in as document 5 with the tag `via-mcp`. A second use of the link
received 404, and a text file received 415. `/mcp` on the upload hostname
received 404.

## Phase 4: semantic search and download links

Goal: an agent finds a document by its meaning, in English, Spanish or
Portuguese, also when the words of the question are not the words of the
document. The agent does the retrieval-augmented generation itself: a tool
gives it the passages that match, and the agent writes the answer.

Do not use the AI features of Paperless 3.3.4 (`PAPERLESS_AI_ENABLED`). The
chat at `POST /api/documents/chat/` gives an answer from the LLM of
Paperless, not the passages, and its vector index is not reachable.

Decided (2026-10-31):

- The server keeps the token of `paperless-mcp` for the sync of the index.
  Each search still filters the results with the token of the caller.
- Text in a page or in a document can tell claude.ai to make a download
  link. I accept this risk. A link works once, for 15 minutes, and only for a
  document that the caller can view.
- A Telegram bot that sends documents is a later idea. Telegram keeps a
  readable copy of the chats of a bot. I accept this risk.

### Index

- **Storage.** The database `paperless_mcp` on `postgres16` (CloudNativePG)
  has the extensions `vector` and `unaccent`. Each document has one metadata
  chunk (title, correspondent, document type, tags, date) and its content
  chunks of about 1000 characters. The metadata chunk makes "proposal" or
  "hipoteca" find a document by its type or title. Each chunk has a
  `vector(1024)` column (HNSW, cosine) and a `tsvector` column (GIN, `simple`
  with `unaccent`, because the documents mix languages).
- **Embeddings.** Text Embeddings Inference (TEI) on the AI host
  (`10.30.50.13:11435`) makes them with the model `Qwen/Qwen3-Embedding-0.6B`,
  in float16 on a GPU. The model stays in GPU memory. Ollama unloads an idle
  model, so the first query after an idle time failed the timeout of the
  server, which then answered with words only and no error. The stack is
  `hosts/ai/stacks/embeddings` of this repo. The text of the documents does not
  leave home. The model came from a bake-off on the 5 Spanish documents of the
  archive, with 20 questions in English and Portuguese. `qwen3-embedding:0.6b`
  gave the correct document first 20 times of 20, `bge-m3` 18 times and
  Harrier 0.6B 19 times. The notes server stays on `bge-m3`.
- **Sync.** The server syncs at start and every 10 minutes with the token of
  `paperless-mcp`. It deletes the rows of a document that is not visible any
  more, and indexes a new document or a document with another `modified`
  time. Once a day it makes the metadata chunks again, because a rename of a
  tag does not change `modified`. If the embedding server does not answer, the
  sync stops
  and tries again at the next run. It does not delete the index.

### Tools

- `semantic_search(query, limit?)` merges the results by meaning and by words
  (reciprocal rank fusion) in one SQL query. Then it asks Paperless with the
  token of the caller which documents the caller can view, and drops the
  others. For each document it gives the ID, the metadata, the best passage,
  how it matched, and the link to the web UI. The field `strong_match` tells
  if the best match is strong. No model separates correct answers from
  no-match questions completely, so `strong_match` is a hint, not a proof. The
  description of the tool tells the agent to try `search_documents` and the
  filters before it says that a document does not exist. If Ollama does not
  answer, the tool uses the word results only and says so.
- `request_download(document_id, original?)` makes a link
  `https://paperless-upload.${SECRET_DOMAIN}/download/<token>`, as
  `request_upload` does for uploads. The link works once, also when the
  download fails, and expires after 15 minutes. The server streams the file
  with the token of the caller, so the tool refuses a document that the
  caller cannot view. The response has `Content-Disposition: attachment`.

## Deploy of phase 4

The fork is `jaimemachado/paperless-mcp`, pull requests 2, 3 and 4
(`/metrics` and traces) and the time of each request type (pull request 4). The image is pinned by digest. The tools exist only
when the server has these variables:

- `semantic_search`: `DATABASE_URL`, `EMBEDDING_PROVIDER` (`openai` for TEI),
  `EMBEDDING_URL`, `EMBEDDING_MODEL` and `PAPERLESS_SYNC_API_KEY`;
- `request_download`: `PAPERLESS_UPLOAD_API_KEY` and
  `PAPERLESS_UPLOAD_PUBLIC_URL`, as for the upload links.

The download links are in memory, as the upload links are. Keep one replica.

The route is the one of phase 3. It now has the path prefixes `/upload/` and
`/download/`. The CiliumNetworkPolicy lets envoy-external send only `GET` to
`/download/<token>`. The same limit of 30 requests a minute applies. A
download link works once, so the limit is still right.

The network policy has three more rules for the search:

- egress to Postgres (`postgres16`, port 5432);
- egress to the embedding server (`10.30.50.13/32`, port 11435);
- ingress from Prometheus, for `GET /metrics`, on the same port;
- ingress from `postgres16`, for the replies. When the primary runs on the
  same node, Cilium drops its replies, and the connection times out.

Do these steps in this sequence:

1. Merge the pull request 2 of the fork. `docker-publish.yml` pushes the
   image.
2. Make the field before the merge of the home-ops branch, because the
   ExternalSecrets need it. I made it on 2026-10-31.
   - Add the field `paperless_mcp_db_password` to the item `Paperless` in the
     vault `Home-Ops`.
   - Use the generator of the 1Password app: 32 letters and digits.
   - Use the app, because `op item edit` refuses this item.
   - The field `paperless_mcp_api_token` exists from phase 1.
3. Merge the home-ops branch.
4. Examine the result:
   - the ExternalSecrets `paperless-mcp-db`, `paperless-mcp-search-secret`
     and `paperless-mcp-upload-secret` are synced;
   - the `Database` `paperless-mcp` is ready;
   - the pod of `paperless-mcp` runs the new image;
   - the log of the pod shows the first sync with 5 documents added. If the
     log shows a connection that times out, examine the egress and ingress
     rules for Postgres and Ollama.
5. In the LiteLLM dashboard, add `semantic_search` and `request_download` to
   the keys that list their tools: `claude-ai` and Open WebUI.

The acceptance test runs against the real archive. Start
`kubectl port-forward -n selfhosted svc/paperless-mcp 3000:3000`. Then call
`/mcp` with a Paperless token. You can also call the LiteLLM `/mcp` gateway,
as claude.ai does. Do these steps:

1. Ask the 20 questions of the bake-off with `semantic_search`. For each
   question, examine that the correct document is first.
2. Search for an exact number from the text of document 2. Examine that the
   result has document 2.
3. Upload a new document through a link. Wait 10 minutes or less. Search for
   its content. Examine that the result has the new document.
4. Move a document to the trash in Paperless. Search for its content before
   the next sync. Examine that the document is not in a result.
5. Call `request_download` for a document. Open the link, and examine that it
   gives the file. Open the link again, and examine that it is refused.

## Open questions

- Decided (2026-10-31): yes, the key `claude-ai` has `paperless`, next to
  `memini`, with view only. The risk below is accepted.
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
- Paperless itself stays internal. Only the upload page, the download links
  and LiteLLM's `/mcp` are public.

## Notes from the deploy (2026-10-30)

- The MCP pod has ingress rules. When Paperless runs on the same node,
  Cilium checked the SYN-ACK of the Service connection against them and
  dropped it, so every call timed out. The policy now allows ingress from
  the Paperless pod (replies only; Paperless opens no connection to it).
- Full-text search filters by the permissions stored in the search index.
  Access given in the database (not through the API) needs
  `document_index reindex`. Run it as the user `paperless`
  (`su paperless -s /bin/sh -c "..."`), never as root through
  `kubectl exec`: a root-owned index breaks every save.
- paperless-ai creates tags, correspondents and document types as its own
  user, so nobody else could see them ("Private" in the UI and for the
  agents). The CronJob `paperless-ai-share-objects`
  (`selfhosted/paperless/ai/cronjob.yaml`) removes the owner from these
  objects five minutes after each scan of paperless-ai. It uses the token of
  paperless-ai, and needs the change permission on tags, correspondents and
  document types in the group `ai-services`.
