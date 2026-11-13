# ai: the GPU host for local models

`ai.local.${SECRET_DOMAIN}` (`10.30.50.13`) is a Debian 12 LXC container on the
Proxmox host `jmn-medusa`. It runs Docker stacks that use the three GeForce GTX
1660 SUPER GPUs of the host. It is not part of the cluster, so nothing in
`kubernetes/` deploys it. This folder is the record of how to rebuild it.

| Path here | On the host |
| --- | --- |
| `stacks/<name>/compose.yaml` | `/opt/stacks/<name>/compose.yaml`, managed with Dockge |
| `dockge/compose.yaml` | `/opt/dockge/compose.yaml` (web UI on port 5001) |
| `docker/daemon.json` | `/etc/docker/daemon.json` |
| `proxmox/nvidia-persistenced.service` | `/etc/systemd/system/` on `jmn-medusa` |

## What runs here

| Stack | Port | Used by |
| --- | --- | --- |
| `ollama` | 11434 | memini embeddings (`qwen3-embedding:4b`, Q4_K_M), LiteLLM `ollama/local` (`qwen3:8b`) |
| `embeddings` | 11435, 11436 | `tei-qwen3-06b` for the Paperless MCP; `tei-bge-m3` for the notes MCP |
| `fast-wir-2` | 10300 | speech to text (Wyoming), Home Assistant. The older `fast-whisper-pt-br` stack is not running |
| `text-speach-1` | 10201 | text to speech (Wyoming), a test |
| `kokoro-pt-br` | 8880 | text to speech, a test |
| `phonon-pt-br` | 8881 | text to speech, a test. HF_TOKEN is in the `.env` of the stack on the host, never in git |
| `qweanvoice` | 7860 | text to speech with a web studio, a test |
| `fast-whisper-pt-br` | - | speech to text, the version before `fast-wir-2` |
| `piper-pt-br` | 10200 | text to speech (Wyoming), Home Assistant |
| `ocr-service` (`ocr`) | 8000 | OCR |
| `tika` | 9998 | document text extraction |
| `node-exporter` | 9100 | Prometheus (`scrapeconfigs/node-exporter.yaml`) |
| `nvidia-gpu-exporter` | 9835 | Prometheus (`scrapeconfigs/nvidia-gpu-exporter.yaml`), with one series for each process on a GPU |

The Ollama models are in the Docker volume `ollama_ollama` (about 32 GB):
`qwen3:8b` (Q4_K_M), `qwen3-embedding:0.6b` (Q8_0), `qwen3.5:4b` (Q4_K_M),
`qwen3-embedding:4b` (Q4_K_M), `bge-m3` (F16) and `nomic-embed-text` (F16). The
Whisper and Piper data are in `/docker/fasterwhisper` and `/docker/piper`.

The `embeddings` stack answers embedding models with Text Embeddings Inference
(TEI) instead of Ollama. TEI loads the model at start and keeps it in GPU
memory. Ollama unloads an idle model after 5 minutes, so the first query after
an idle time waits for the load and fails the timeout of the Paperless MCP
server. The server then answers with words only, without an error.

`qwen3-embedding:4b` stays on Ollama: in float16 it needs about 8 GB, more than
the 6 GB of a GTX 1660 SUPER. The quantized GGUF of Ollama fits. The TEI image
for Turing is `turing-1.9`, the only build for the SM75 of these cards, and it
needs `--dtype float16` because bfloat16 needs Ampere or newer.

### The GPUs

The host has three GTX 1660 SUPER, with 6 GiB each. Every service that uses a
GPU is pinned to one card, so that a model cannot take the memory of another:

| GPU | What is on it | Used memory |
| --- | --- | --- |
| 0 | `qwen-tts` (2.6), `kokoro-tts` (0.7), the `bge-m3` of Ollama (0.5) | 3.7 GiB |
| 1 | nothing. Ollama loads `qwen3:8b` here, about 5.6 GiB | 0 to 5.6 GiB |
| 2 | the two TEI containers (2.5), the Whisper model of `fast-wir-2` (1.6), `phonon-pt-br` (up to 1.6 at its first request) | 4.1 GiB, up to 5.7 |

Ollama is pinned with `device_ids: ["0", "1"]`. With `count: all` it loaded
`qwen3:8b` over GPU 1 and GPU 2 for about 5 minutes each hour, and took 2.1
GiB of the 6 GiB that the two TEI containers share.

Two things to know when a GPU changes:

- **A change of `device_ids` does not recreate the container.** Docker Compose
  does not count it as a change of the configuration, so `docker compose up -d`
  does nothing and doco-cd reports a successful deploy. After a change of the
  GPU of a stack, run `docker compose up -d --force-recreate` in its folder.
- **The GPU memory of a container takes a few seconds to disappear** after the
  recreate. A check right after it still shows the old process on the old card.

## Auto-deploy (doco-cd)

`doco-cd` runs from `/opt/doco-cd`, polls this repo every 30 minutes, and runs
`docker compose up` for a stack when a file named in `.doco-cd.<target>.yml`
changes on `main`. The targets are in `doco-cd/poll-config.yml`. Three targets
exist today:

- `embeddings` (`hosts/ai/stacks/embeddings`);
- `ai-host` (`.doco-cd.ai-host.yml`, one document for each stack): `kokoro-pt-br`,
  `piper-pt-br`, `node-exporter` and `nvidia-gpu-exporter`;
- `ai-host-extra` (`.doco-cd.ai-host-extra.yml`): `tika`, `ocr`, `fast-wir-2`,
  `text-speach-1`, `phonon-pt-br` and `qweanvoice`. These need the absolute
  paths and the `.env` files described below.

The list of targets that doco-cd polls is `/opt/doco-cd/data/poll-config.yml` on
the host. It is a copy. A change to `hosts/ai/doco-cd/poll-config.yml` or to
`hosts/ai/doco-cd/compose.yaml` in git does nothing until you copy the file to
`/opt/doco-cd` and run `docker compose up -d` there.

A merge to `main` changes the container of these stacks at the next poll (up to
30 minutes). With `force_recreate: false`, a poll with no change in a compose
file should restart nothing. The first poll of a new stack can still recreate its
container once: on 2026-11-04 it recreated `kokoro-tts` (the GPU pin changed) and
also `piper`, whose file had not changed. The exporters kept running. Check the
start time of the containers after the first poll of a new stack.

After each deploy, doco-cd removes the images that no container uses any more
(`prune_images: true`). Without it, each update of the kokoro image (8 GB) left
the old one on the root disk, which was 92% full on 2026-11-04. It never removes
an image that a container still uses. Look at the disk with
`docker system df`, and at the free space of `/` in the alert
`CephNodeDiskspaceWarning`.

### Which stacks can be automatic

doco-cd runs `docker compose` from its own copy of the repository, not from
`/opt/stacks/<name>`. So a stack is safe to automate only when its compose file
does not depend on files that live in the stack folder of the host:

| Stack | Automatic? | Reason |
| --- | --- | --- |
| `kokoro-pt-br`, `piper-pt-br`, `node-exporter`, `nvidia-gpu-exporter` | yes (`ai-host`) | no relative path, no variable from a `.env` |
| `embeddings` | yes (`embeddings`) | named volumes only |
| `tika` | yes (`ai-host-extra`) | the 12 external networks that it declared were not used by the service, and 7 do not exist on the host: they were removed |
| `fast-wir-2`, `text-speach-1`, `ocr` | yes (`ai-host-extra`) | the relative bind mounts are now absolute (`/opt/stacks/<name>/...`), so the data stays where it is |
| `phonon-pt-br`, `qweanvoice` | yes (`ai-host-extra`) | the variable comes from `env_files: /opt/stacks/<name>/.env`; the doco-cd container mounts `/opt/stacks` read-only |
| `ollama` | never | a redeploy restarts the models that memini and LiteLLM use, and its volume holds 13 GiB |
| `fast-whisper-pt-br` | no | not running: a deploy would start it (it takes the port 10300 of `fast-wir-2`) |

A new stack follows the same rules: no `./` path (use `/opt/stacks/<name>/...`),
no external network that does not exist on the host, and its variables in the
`.env` file of the stack on the host (`hosts/ai/env-from-1password.sh` writes it).
The name of the document must be the name of the Compose project that exists on
the host, or doco-cd makes a second project next to the first.

The doco-cd container can read every file in `/opt/stacks`, including the `.env`
files. It holds the docker socket already, which is root on the host, so this
adds little, but keep secrets out of any other file of that folder.

Install it:

1. Copy `doco-cd/` to `/opt/doco-cd` and `poll-config.yml` to
   `/opt/doco-cd/data/poll-config.yml`.
2. `cd /opt/doco-cd && docker compose up -d`.

```sh
docker logs -f doco-cd                       # watch it poll and deploy
cd /opt/doco-cd && docker compose restart    # force an immediate poll
```

The file in git defines a stack that doco-cd deploys, not the copy in
`/opt/stacks`. Edit the file in git. To deploy another stack automatically, add
a target to `poll-config.yml` and a `.doco-cd.<target>.yml` at the root of the
repo. Do not add a target for `ollama`: a redeploy restarts the models that
memini and LiteLLM use.

## Monitoring

- Disk, memory and CPU: the default node-exporter alerts of
  kube-prometheus-stack (`NodeFilesystemAlmostOutOfSpace` and others).
- `AiHostGpuMissing`: fewer than 3 GPUs report (`prometheusrules/ai-host.yaml`).
- `AiHostOllamaDown`: the blackbox probe `ai-host` fails on port 11434.
- `AiHostTeiDown`: the blackbox probe `ai-host` fails on port 11435 or 11436. Without the embedding server
  the Paperless MCP search uses words only, and no error shows.
  `AiHostTeiNotScraped` fires when Prometheus cannot read `/metrics` of a TEI
  container (`scrapeconfigs/tei.yaml`).
- `PaperlessMcpEmbedErrors`, `PaperlessMcpSyncFailing` and
  `PaperlessMcpSearchWordsOnly`: the same failure seen from the Paperless MCP
  server.

The dashboard **AI Stack** (folder AI, `kubernetes/apps/ai/litellm/app/dashboard`)
shows the GPUs, the processes that hold memory on them, the embedding servers
and the requests through LiteLLM. The dashboard **Nvidia GPU Metrics** has the
detail of each GPU.

### The process table of the GPU dashboard

The table "GPU Processes" is empty when the exporter has no per-process
series. The image `nvidia_gpu_exporter:1.17.0-nvml` exports them with
`--collect.compute-apps`. The exporter needs `pid: host` to see the processes of
the other containers. The image 1.15.1 and the `exec` backend have no such
series.

## Known failures

### Docker does not start: "overlay2 driver not supported"

The message is wrong: the root disk is full. Docker cannot create the test
directories of the overlay2 check. On 2026-10-25 the disk had been full since
2026-09-27, because Docker kept container logs without a limit.

1. Make space: `truncate -s 0` the largest `/var/lib/docker/containers/*/*-json.log`.
2. Start Docker: `systemctl reset-failed docker && systemctl start docker`.
3. Remove unused images: `docker image prune -a`.

`docker/daemon.json` now limits each log to 3 × 50 MB.

### GPU containers fail: "nvml error: driver not loaded"

If `/dev/nvidia0` and the others in the container are empty files with mode
`----------`, the devices did not exist on the Proxmox host when the
container started. The NVIDIA `.run` installer creates no unit that makes them
at boot.

1. On `jmn-medusa`: `nvidia-smi`, then check `ls -l /dev/nvidia*` (`crw-…`).
2. Install `proxmox/nvidia-persistenced.service` and
   `systemctl enable --now nvidia-persistenced`. It starts before
   `pve-guests.service`, so the devices exist before the guests start.
3. Restart the container: `pct reboot <CTID>`.

## Rebuild

1. On `jmn-medusa`: create a Debian 12 LXC with the GPU passthrough of
   `proxmox/lxc.conf` (TODO: add this file from `/etc/pve/lxc/<CTID>.conf`),
   and install the NVIDIA driver of the host version (570.144) inside it,
   without the kernel module.
2. Install Docker and the NVIDIA container toolkit, and copy
   `docker/daemon.json`.
3. Copy `dockge/` to `/opt/dockge`, `stacks/` to `/opt/stacks`, and `doco-cd/`
   to `/opt/doco-cd` with `poll-config.yml` in `/opt/doco-cd/data/`. Then run
   `docker compose up -d` in `/opt/dockge` and in `/opt/doco-cd`. Start the
   stacks from Dockge.
4. Pull the models: `docker exec ollama ollama pull qwen3:8b`,
   `qwen3-embedding:4b`, `qwen3-embedding:0.6b` and `bge-m3`. The `embeddings`
   stack downloads its own models at the first start.

## Open issues

- `fast-whisper-pt-br` and `tika` declare external networks of stacks that no
  longer exist. No service uses them; remove the declarations.
- `ollama` uses `ollama/ollama` with no version tag.
