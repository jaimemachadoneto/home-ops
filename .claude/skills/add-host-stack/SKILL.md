---
name: add-host-stack
description: Add or change a Docker Compose stack on a home-ops Docker host (the ai GPU host or the semaphore host) that doco-cd deploys from main. Use when the user asks to deploy, change, stop or remove a container or a stack on a host outside the Kubernetes cluster, or to change doco-cd.
---

# Add or change a stack on a Docker host

doco-cd runs on each host. It polls `main` every 30 minutes, and runs
`docker compose up` for each stack that a `.doco-cd.<target>.yml` file at the
root of the repo names. A merge is a live change on the host.

Read `hosts/<host>/README.md` first. It has the current list of stacks, the
GPUs and the known failures.

| Host | Stacks | Targets and their deploy files | Poll config |
| --- | --- | --- | --- |
| `ai` (GPU host) | `hosts/ai/stacks/<name>/compose.yaml` | `ai-host` (`.doco-cd.ai-host.yml`), `ai-host-extra` (`.doco-cd.ai-host-extra.yml`), `embeddings` (`.doco-cd.embeddings.yml`) | `hosts/ai/doco-cd/poll-config.yml` |
| `semaphore` | `hosts/semaphore/docker-compose.yml` | `semaphore` (`.doco-cd.semaphore.yml`) | `hosts/semaphore/doco-cd/poll-config.yml` |

## Rules for a stack that doco-cd deploys

doco-cd runs Compose from its own copy of the repo, not from
`/opt/stacks/<name>` on the host. Therefore:

1. Do not use a relative path (`./data`). Use an absolute path on the host
   (`/opt/stacks/<name>/...`) or a named volume. A stack with an absolute
   bind mount goes in the target `ai-host-extra`.
2. Do not name an external network that does not exist on the host.
3. A compose file in git holds `${VARIABLE}` only. The value goes in the
   `.env` file of the stack on the host. `hosts/ai/env-from-1password.sh`
   writes the `.env` files from 1Password. Now it knows only `qweanvoice`.
   To add a stack with secrets, add a case for the stack to that script,
   and ask the user for the 1Password field names. Do not guess a field
   name.
4. The `name` of the document in `.doco-cd.<target>.yml` is the name of the
   Compose project that already runs on the host. A different name makes a
   second project next to the first.
5. In a document for the ai host, keep `force_recreate: false`,
   `remove_orphans: true` and `prune_images: true`, as in
   `.doco-cd.ai-host.yml`. The semaphore document is different
   (`force_image_pull: true`). Do not change it unless the user asks.
6. Pin the image to a version tag, or to a digest. Read the tag from the
   upstream release. Do not write a tag from memory.
7. A GPU stack names its GPU. Read "The GPUs" in `hosts/ai/README.md`
   before you choose one: each model takes memory from the others.

## Stacks that stay out of doco-cd

- `ollama`: never. A redeploy restarts the models that memini and LiteLLM
  use.
- A stack that the user stops on purpose, such as `qweanvoice`. A deploy
  starts it again.

## Procedure

1. Write or change `hosts/<host>/stacks/<name>/compose.yaml`. Copy a
   neighbour stack: `node-exporter` (simple), `embeddings` (named volumes,
   GPU), `fast-wir-2` (absolute bind mounts).
2. Add a document to the correct `.doco-cd.<target>.yml`, or change it.
3. If the stack is new and needs its own target, add the target to
   `hosts/<host>/doco-cd/poll-config.yml`. That file is a copy on the host:
   tell the user to copy it to `/opt/doco-cd/data/` and restart doco-cd.
   Without that step, nothing deploys.
4. If the stack serves a web page in the cluster, the route is in
   `kubernetes/apps/external-ingresses/`. Change it in the same PR.
5. Update the table "Which stacks can be automatic" in `hosts/ai/README.md`.
6. Verify:

   ```sh
   docker compose -f hosts/<host>/stacks/<name>/compose.yaml config --quiet
   ```

   A warning about a variable that is not set is correct: the value is in
   the `.env` file on the host.
7. Tell the user when the change takes effect: up to 30 minutes after the
   merge. After the first poll of a new stack, tell the user to examine the
   start time of the other containers on the host. A new start time shows
   that the deploy also restarted them.

## Remove or rename a stack

`remove_orphans` and the name of the document decide what doco-cd removes.
Before you remove a document, rename a folder or rename a document, tell the
user what stops and which volumes stay on the host. Do the change only after
the user agrees.
