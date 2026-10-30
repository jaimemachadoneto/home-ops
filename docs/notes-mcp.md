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
- Meaning search with a local model (no outside service): point its
  embedding provider at Ollama through LiteLLM. memini already uses
  `qwen3-embedding:4b` (see `ai.md`); use the same model unless another one
  tests better on my notes.
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

## Phase 4 (optional): raw files without Syncthing

A WebDAV server (for example `rclone serve webdav`) on the same volume, only
reachable over the VPN or through the cluster's authenticated ingress. For
devices that shouldn't hold a full copy.

## Open questions

- Vault size: how many notes? This decides the first full indexing time.
- Which folders must stay out of the index?
- Should agent changes be applied straight away, or wait in a review queue
  for certain folders?
