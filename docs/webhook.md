# Webhook service

A webhook server runs in the namespace `selfhosted`
(`kubernetes/apps/selfhosted/webhook/`). A hook is a path, a signature check
and a fixed script. GitHub calls the server when you push to `main`. The first
hook makes doco-cd on the AI host deploy at once, so the deploy does not wait
for the 30-minute poll of doco-cd. The poll stays as a safety net.

## How a push reaches doco-cd

1. GitHub sends the push to `https://hooks.<domain>/hooks/doco-cd`.
2. The hook runs only when all three rules are true: the HMAC of the body
   matches `GITHUB_WEBHOOK_SECRET`, the event is `push`, and `ref` is
   `refs/heads/main`.
3. The script `doco-cd-deploy.sh` signs the same body with
   `DOCO_CD_WEBHOOK_SECRET`. It posts the body to the targets `embeddings`,
   `ai-host` and `ai-host-extra` of doco-cd on `10.30.50.13:8081`.

The image is `ghcr.io/jaimemachadoneto/webhook-runner`. Its repository is
`jaimemachadoneto/webhook-runner`. It holds adnanh/webhook, `curl` and
`openssl`.

## Secrets

The 1Password Secure Note `webhook` (vault `Home-Ops`) has two fields. An
ExternalSecret makes the Secret `webhook-secret` from them.

| Field | Used by |
| --- | --- |
| `GITHUB_WEBHOOK_SECRET` | GitHub to the server. It is also the secret of the GitHub webhook. |
| `DOCO_CD_WEBHOOK_SECRET` | The server to doco-cd. It is also `WEBHOOK_SECRET` in `/opt/doco-cd/.env` on the AI host. |

To rotate a secret, change the field in 1Password. Then change the same value
in its second place, and restart the pod.

## Add a hook for another service

1. Write the script in `app/scripts/<name>.sh`. Read the raw body from the file
   in `$PAYLOAD_FILE`. Never let request data select a command or a target.
2. Write the hook in `app/config/<name>.yaml`. Copy `doco-cd.yaml`: keep the
   signature rule, and keep the rules for the event and the branch.
3. Add both files to the `configMapGenerator` in `app/kustomization.yaml`.
   The server reads one hook file for each `-hooks=` argument in
   `app/helmrelease.yaml`, so add an argument for the new file.
4. If the script calls a new address, add it to
   `app/ciliumnetworkpolicy.yaml`. The server can call only doco-cd today.
5. Add a test in `tests/`, as in `test_doco_cd_deploy.py`.
6. Make a GitHub webhook for the new path. Use the content type
   `application/json`. Without it, the server cannot read `ref`.

## Port 8081 on the AI host

doco-cd listens on `10.30.50.13:8081`. A rule in the chain `DOCKER-USER`
allows only the four cluster nodes. `ufw` is not installed on the host, and
Docker bypasses it for published ports. The script and the unit are in
`hosts/ai/doco-cd/firewall/`. Change the list of nodes in the script when a
node changes. See `hosts/ai/README.md`.

## Test

- Send a push to `main`, or open the deliveries of the webhook in the GitHub
  settings. doco-cd logs one job for each target within seconds:
  `docker logs doco-cd` on the AI host.
- A request with a bad signature gets an error. A request with the wrong
  branch or event gets 200, and the script does not run.
- A replay of a captured signed request redeploys an older commit, because
  doco-cd deploys the commit in the payload. The firewall limits the replay
  to the cluster nodes.
