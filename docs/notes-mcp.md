# Plan: a notes MCP server, the only way agents use my notes

Status: phase 3 is in progress (2026-10-30); see the "Deploy" section. Moved
here from nix-config, where phases 1 and 2 are carried out; phase 3 and 4 are
home-ops work. Hostnames follow this repo (`${SECRET_DOMAIN}`); nix-config
reads its own from nix-secrets.

## Goal

One vault, two kinds of access:

- **Me:** the Obsidian vault (`~/Notes`), synced by Syncthing to my own
  devices, where I read and edit it as plain files.
- **Agents** (Claude Code, OpenCode, anything that speaks MCP): only through a
  notes MCP server, from any machine, with no local copy. Through it they
  search by meaning (I often don't remember the words I used), read, and
  create or update notes. They never touch the files directly.

## What exists today

- The vault is synced with Syncthing. The always-on Syncthing device runs in
  the home-ops cluster; the phone and the workstation (`jaime-ws-nixos`) sync
  with it.
- nix-config's `modules/home/syncthing/` only works on Linux (`isLinux`
  guard) and is enabled only on `jaime-ws-nixos`, so the MacBook has no notes.
- The workstation commits and pushes `~/Notes` to a GitHub repo every 5
  minutes (`notes-autosync`), which gives history and a backup.
- memini (agent memory, in home-ops) and the LiteLLM MCP gateway (in
  home-ops) are enabled only on the workstation (`memini`, `litellmMcp`
  features). Claude Code reaches the gateway's servers through one `litellm`
  MCP entry; the list of servers is `litellmMcpServers` in
  `modules/home/claudcode/default.nix`.

## Decisions

- The cluster's Syncthing folder is the master copy of the vault.
- Every device of mine gets a full copy through Syncthing (the phone already
  does). WebDAV for devices without Syncthing is optional and deferred.
- The synced folders are for me only. Agents never read or write `~/Notes`
  directly; they always go through the notes MCP server, for reading and for
  updating. This keeps every agent change in one place that can check
  versions, stay atomic and be logged.
- The notes MCP server sits behind the existing LiteLLM gateway, so it
  reuses the gateway's key and needs one name in `litellmMcpServers`.
- Search is hybrid: meaning search (embeddings) plus word search (full text),
  merged into one ranked list. Meaning search alone misses exact names,
  codes and numbers.
- memini stays separate (short agent memories, not documents), but the notes
  search may also return matching memini entries.

## Phase 1: notes on the MacBook (nix-config)

1. Make `modules/home/syncthing/` work on macOS: drop the `isLinux` guard
   (Home Manager's `services.syncthing` supports Darwin), and run the
   `notes-autosync` job through `launchd.agents` instead of systemd on
   Darwin. Only one machine needs autosync; keep it on the workstation and
   make it optional elsewhere, or two machines will race to commit.
2. Set `features.syncthing = true` in `configurations/machine/Jaimes-MacBook-Pro.nix`.
3. Accept the MacBook's device ID on the cluster's Syncthing device.

Done when: `~/Notes` on the MacBook matches the phone, and an edit on either
reaches the other.

## Phase 2: agent tools on the MacBook (nix-config + nix-secrets)

1. Make `keys/memini` and `keys/litellm` decryptable by the MacBook's age key
   in nix-secrets (`.sops.yaml`, then re-encrypt).
2. Set `features.memini = true` and `features.litellmMcp = true` on the MacBook.
3. Keep agents out of the synced folder on every machine: in the
   claudcode module, merge deny rules into `~/.claude/settings.json` (the
   same way `claudeStatusLine` merges `statusLine`), for example
   `Read(~/Notes/**)`, `Edit(~/Notes/**)`, `Write(~/Notes/**)`, and
   Bash commands that name `~/Notes`. Do the same for OpenCode's
   permission settings. Add a line to the global agent instructions: notes
   are read and changed only through the notes MCP server.

Done when: a Claude session on the MacBook lists the memini and litellm MCP
servers, and asking it to open a file in `~/Notes` is refused.

## Phase 3: notes MCP server with hybrid search (home-ops)

### Use a fork of obsidian-mcp

[maxkuminov/obsidian-mcp](https://github.com/maxkuminov/obsidian-mcp) (MIT)
already does most of this: it runs without the Obsidian app, has meaning
search (pgvector) plus word search (Postgres full text), Ollama or any
OpenAI-compatible embeddings, note create/edit/move/delete with content-hash
preconditions, atomic writes, soft delete into `.trash/`, exclude patterns,
Bearer API keys (read or read-write) and OAuth 2.0 PKCE (works with
claude.ai), and Kubernetes manifests.

It is a small project (about 18 stars, one main maintainer), so run it from
a fork under my own GitHub account:

1. Fork it: `gh repo fork maxkuminov/obsidian-mcp --clone=false`.
2. Build the container image from the fork (GitHub Actions to GHCR), and
   deploy that image, pinned by digest. Never deploy upstream images directly.
3. Pull upstream changes deliberately: a scheduled job or Renovate opens a PR
   in the fork when upstream moves; read it before merging.
4. Keep my own changes (the gaps below) on a branch, rebased on upstream, and
   offer the generic ones upstream.

Fallback if it fails the tests below: Basic Memory
([basicmachines-co/basic-memory](https://github.com/basicmachines-co/basic-memory),
AGPL-3.0, mature, hybrid search with FastEmbed), which needs its own
authentication in front of it for remote use and may not index edits made
outside its tools.

### Requirements, and how obsidian-mcp meets them

- Reads the vault from the same storage as the cluster's Syncthing folder,
  read-write (the server is the agents' only way to change notes). The
  `syncthing` PVC is `ceph-block`, which is RWO (see `storage.md`), so a
  separate pod cannot mount it. Run obsidian-mcp as a second container in
  the syncthing pod (`kubernetes/apps/selfhosted/syncthing`), sharing the
  volume; the vault is at `/var/syncthing/notes`. The alternative, moving the
  PVC to `ceph-filesystem` (RWX), changes the backup and restore of the
  vault, so prefer the shared pod.
- Meaning search with a local model (no outside service): `bge-m3` on the
  Ollama host, through the native Ollama provider. The first choice was
  `qwen3-embedding:4b`, as memini uses, but one batch of chunks took longer
  than the request timeout of the server.
- Word search for exact names, codes and numbers: built in.
- Storage: PostgreSQL 16+ with pgvector 0.8+, outside the synced folder.
  A database on the CNPG cluster `cluster16`
  (`kubernetes/apps/database/cloudnative-pg/cluster/`). No cluster enables
  pgvector today, and its image (`ghcr.io/cloudnative-pg/postgresql:16.4-29`)
  may ship a pgvector older than 0.8: check, and update the image or use a
  small dedicated CNPG cluster. Include the database in the CNPG backups
  (see `cnpg-backup-review.md`); the index can be rebuilt, but keys and the
  change log cannot.
- Freshness: it re-indexes on a timer (`INDEX_INTERVAL_SECONDS`, default
  300). Set it to about 60 so phone edits are searchable within a minute.
- Safe writes: edits accept `expected_hash` from the last read and are
  refused if the note changed. Gap: the check is optional; make it required
  for every write in the fork, so an agent can never overwrite my edits.
- Privacy: folders to keep out go in `EMBEDDING_EXCLUDE_PATTERNS`. Gap: check
  that excluded folders are also hidden from read, list and write tools, not
  only from the index; add that in the fork if not.
- Audit: it logs API key usage. Gap: check it records each change (time,
  tool, note); the git autosync keeps the full history either way, so any
  change can be undone.
- Gaps to check, and add in the fork if missing:
  - `recent(days)`: notes changed in the last N days.
  - `related(note)`: notes closest in meaning to a given one (it has the
    wikilink graph; this is about meaning).
  - `conflicts()`: Syncthing conflict copies (`*.sync-conflict-*`) waiting
    for me, kept out of the index.
  - Optional: matching memini entries in search results, marked as such.

### Deploy

- The fork's image as a second container in the syncthing HelmRelease, with
  the vault volume, the Postgres database, and the embedding provider set to
  LiteLLM/Ollama. Use its Kubernetes manifests only as a reference for
  settings. Extend the syncthing CiliumNetworkPolicy for Postgres, LiteLLM
  and the gateway's calls in.
- Two API keys: one read-write for my agents, one read-only for testing.
- Register it as a server in the LiteLLM MCP gateway, and add its name to
  `litellmMcpServers` in nix-config.
What is in git (2026-10-30):

| Piece | File |
| --- | --- |
| `postgres16` on `16.15-standard-bullseye` (pgvector 0.8.6, the same glibc as before) | `database/cloudnative-pg/cluster/cluster16.yaml` |
| Role `obsidian_mcp`, database `obsidian_mcp` with the extension `vector` | `cluster16.yaml`, `database/cloudnative-pg/cluster/obsidian-mcp.yaml` |
| Container `obsidian-mcp`, Service `syncthing-notes-mcp` (port 80), panel route `notes.${SECRET_DOMAIN}` | `selfhosted/syncthing/app/helmrelease.yaml` |
| Only Envoy, LiteLLM (only `/mcp`) and the kubelet can reach port 8000 | `selfhosted/syncthing/app/ciliumnetworkpolicy.yaml` |
| Gateway entry `notes` | `ai/notes-mcp/` |

Facts found during the work:

- Upstream already refuses every path with a part that starts with a dot
  (`is_hidden_path` in `src/services/vault.py`), for read, list, write, move
  and delete. Agents cannot change `.obsidian/plugins/*/main.js`.
- `WRITE_PRECONDITION_REQUIRED=true` makes the hash required. No fork change
  is necessary for it.
- In single-user mode the panel has no login, and it can create API keys.
  Authentik forward auth is its gate: `https://notes.${SECRET_DOMAIN}/admin`,
  for `authentik Admins` only. On port 8000, the CiliumNetworkPolicy lets in
  only Envoy (behind Authentik), the kubelet probes and the LiteLLM gateway.
  The gateway can call only `/mcp` (an L7 rule).
- The `sync` Service publishes the pod when it is not ready, so a failure of
  the MCP container does not stop Syncthing.

First start:

1. In 1Password, create the item `obsidian-mcp` with the fields
   `db_password` and `secret_key`. For each, use `openssl rand -hex 32`.
2. Merge. Check that the pod starts and that the index has all notes:
   `kubectl -n selfhosted logs deploy/syncthing -c obsidian-mcp`.
3. Open `https://notes.${SECRET_DOMAIN}/admin` (Homepage, group AI) and sign
   in with Authentik. Create a read-write key and a read-only key.
4. Put the read-write key in the field `api_key` of the item `obsidian-mcp`.
   The gateway entry `notes` then starts.
5. Add `notes` to `litellmMcpServers` in nix-config.

- claude.ai reaches the gateway through its public route (`docs/ai.md`,
  "claude.ai connector"). That route needs a Cloudflare record; external-dns
  1.23.0 broke it on 2026-10-29, and the Cloudflare instance is back on
  1.20.0. Test each newer version before you keep it (`docs/ai.md`, "The
  public record of litellm and external-dns 1.23.0").
- claude.ai and the Claude phone app (optional, later): they connect from
  Anthropic's cloud, so this needs a public HTTPS entry point using the
  server's OAuth login, for example through a tunnel, with Authentik in
  front (see `authentik-sso.md`). That puts the notes on the internet; do it
  last and on its own.

Done when, from a Claude session on any machine with `litellmMcp`:

- a vague question ("what did I decide about the car?") finds a note that
  never uses those words;
- an exact name or ID finds its note;
- a note edited on the phone shows up in search within a minute;
- an agent's edit reaches the phone through Syncthing;
- an edit with an old hash (the note was edited on the phone in between) is
  refused and leaves my edit intact, and an edit with no hash is refused;
- a note in an excluded folder is invisible to every tool.

## Change the embedding provider or model

The server stores a fingerprint of its embedding configuration: the provider,
the model, the dimensions and the chunk settings. At start it compares the
fingerprint with its settings and exits when they differ, because vectors from
two models in one column make the search wrong without any error. The same
check stops the indexer of a running pod. So a change of provider or model has
a fixed order, and the reset must run before the new settings reach the pod.

Today the server uses `bge-m3` on Ollama (port 11434). The target is the TEI
container `tei-bge-m3` of the ai host (`hosts/ai/stacks/embeddings`, port 11436)
through the OpenAI provider. The vectors of both give a cosine of 1.0000, so the
reset is a precaution of the guard and not a need of the data. It costs a new
embedding of all notes (about 80 notes, a few minutes).

What the reset does, in one transaction: it deletes every row of
`note_embeddings`, recreates the column at the configured dimensions, clears
`embedded_content_hash` of every note, and stores the fingerprint of the new
settings. Notes, links and the word search are not touched. While the notes are
embedded again, the search by meaning does not find the notes that are not yet
done. The word search keeps working.

TEI answers at most 96 inputs in one request, and the server sends at most 96
(`OPENAI_BATCH_LIMIT`). Keep `--max-client-batch-size` of `tei-bge-m3` at 96 or
more.

Steps, in this order:

1. Check that `tei-bge-m3` answers: `curl http://ai.local.<domain>:11436/health`
   returns 200 and `/v1/embeddings` gives 1024 numbers for one input.
2. Run the reset with the new settings. Stop the indexer first so that no pass
   writes between the reset and the new pod: scale the Deployment to 0
   (`kubectl -n selfhosted scale deploy syncthing --replicas=0`). Syncthing is
   in the same pod, so the sync of the phone stops for the length of the reset
   (a few seconds to a minute). Then run a one-off pod with the same image,
   environment and Secret as the `obsidian-mcp` container, with the new
   settings, and the command `python -m scripts.reset_embeddings`:

   ```sh
   kubectl -n selfhosted run notes-reset --rm -i --restart=Never \
     --image=<the image of the container obsidian-mcp> \
     --overrides='<see below>' -- python -m scripts.reset_embeddings
   ```

   The pod needs: `envFrom` the Secret `obsidian-mcp-secret` (it has
   `DATABASE_URL` and `SECRET_KEY`); and these variables, which are the new
   settings: `EMBEDDING_PROVIDER=openai`,
   `OPENAI_BASE_URL=http://ai.local.<domain>:11436/v1`,
   `OPENAI_EMBEDDING_MODEL=BAAI/bge-m3`, `OPENAI_API_KEY=not-used`,
   `EMBEDDING_DIMENSIONS=1024`, `EMBEDDING_ALLOW_PLAINTEXT=true`. The script
   needs no volume: it only talks to Postgres. It prints the fingerprint it
   stored; keep that line.
3. Merge the pull request that changes the settings in the HelmRelease of
   `syncthing` (`EMBEDDING_PROVIDER`, `OPENAI_BASE_URL`,
   `OPENAI_EMBEDDING_MODEL`, `OPENAI_API_KEY`). Scale the Deployment back to 1
   if Flux did not, and wait for the pod.
4. Check the log of the container: no line "fingerprint does not match", then
   "Embedding complete" for the notes. Run a search by meaning from an agent.
5. Compare the number of notes that have an embedding with the number of notes
   that the indexer found (78 on 2026-11-04).

Go back: set the old settings in the HelmRelease (`EMBEDDING_PROVIDER: ollama`,
`OLLAMA_URL`, `EMBEDDING_MODEL: bge-m3`) and run the reset again with them.

Risks, and what protects against them:

- If the new pod starts before the reset, it exits with a critical line that
  names the fields that differ. Nothing is written. Run the reset and let the
  pod start again.
- If the reset fails, the transaction rolls back and the old fingerprint and
  vectors stay. The old settings still work.
- If TEI is down while the notes are embedded again, the indexer retries at
  each pass (every 60 seconds). The notes stay without a vector until it answers.
- A backup of the database `obsidian_mcp` is made by CloudNativePG. Check that
  a recent one exists before the reset.

## Phase 4 (optional): raw files without Syncthing

A WebDAV server (for example `rclone serve webdav`) on the same volume, only
reachable over the VPN or through the cluster's authenticated ingress. For
devices that shouldn't hold a full copy.

## Open questions

- Vault size: how many notes? This decides the first full indexing time.
- Which folders must stay out of the index?
- Should agent changes be applied straight away, or wait in a review queue
  for certain folders?
