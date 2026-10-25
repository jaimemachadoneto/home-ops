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
| `ollama` | 11434 | memini embeddings (`qwen3-embedding:4b`), LiteLLM `ollama/local` (`qwen3:8b`) |
| `fast-whisper-pt-br` | 10300 | speech to text (Wyoming), Home Assistant |
| `piper-pt-br` | 10200 | text to speech (Wyoming), Home Assistant |
| `ocr-service` (`ocr`) | 8000 | OCR |
| `tika` | 9998 | document text extraction |
| `summarizer` (`summirizer`) | 16000 | broken: see below |
| `node-exporter` | 9100 | Prometheus (`scrapeconfigs/node-exporter.yaml`) |
| `nvidia-gpu-exporter` | 9835 | Prometheus (`scrapeconfigs/nvidia-gpu-exporter.yaml`) |

The Ollama models are in the Docker volume `ollama_ollama` (about 32 GB). The
Whisper and Piper data are in `/docker/fasterwhisper` and `/docker/piper`.

## Monitoring

- Disk, memory and CPU: the default node-exporter alerts of
  kube-prometheus-stack (`NodeFilesystemAlmostOutOfSpace` and others).
- `AiHostGpuMissing`: fewer than 3 GPUs report (`prometheusrules/ai-host.yaml`).
- `AiHostOllamaDown`: the Gatus check `ollama` fails.

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
3. Copy `dockge/` to `/opt/dockge` and `stacks/` to `/opt/stacks`, then
   `docker compose up -d` in `/opt/dockge`. Start the stacks from Dockge.
4. Pull the models: `docker exec ollama ollama pull qwen3:8b` and
   `qwen3-embedding:4b`.

## Open issues

- `summarizer` fails at each start (pip cannot build `uvloop`) and points to
  an Ollama at `10.30.3.10`, which does not answer. Remove it or correct it.
- `fast-whisper-pt-br` and `tika` declare external networks of stacks that no
  longer exist. No service uses them; remove the declarations.
- `ollama` uses `ollama/ollama` with no version tag.
