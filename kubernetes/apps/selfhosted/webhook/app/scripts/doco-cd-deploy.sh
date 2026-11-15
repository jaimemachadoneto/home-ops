#!/bin/sh
# Send a GitHub push payload to each doco-cd target, so that doco-cd deploys now
# and does not wait for its poll. doco-cd has no call that only starts a deploy:
# it accepts a signed push payload at /v1/webhook/<target>. The payload is the one
# that GitHub sent. The webhook server already checked the signature and the
# branch, so this script signs the body again with the secret of doco-cd.
#
# Input (environment):
#   PAYLOAD_FILE             file with the raw request body (from the hook)
#   DOCO_CD_WEBHOOK_SECRET   secret of doco-cd, WEBHOOK_SECRET on the host
#   DOCO_CD_URL              base URL of doco-cd (default: the AI host)
set -eu

: "${PAYLOAD_FILE:?PAYLOAD_FILE is not set}"
: "${DOCO_CD_WEBHOOK_SECRET:?DOCO_CD_WEBHOOK_SECRET is not set}"
DOCO_CD_URL="${DOCO_CD_URL:-http://10.30.50.13:8081}"

# A fixed list, never request data: a request must not choose a target.
TARGETS="embeddings ai-host ai-host-extra"

[ -r "$PAYLOAD_FILE" ] || { echo "cannot read $PAYLOAD_FILE" >&2; exit 1; }

# The secret is in the arguments of openssl. The pod has one user and no
# other process, so nobody else can read the process list.
signature=$(openssl dgst -sha256 -hmac "$DOCO_CD_WEBHOOK_SECRET" "$PAYLOAD_FILE" | sed 's/^.*= //')

failed=0
for target in $TARGETS; do
  if curl -fsS --max-time 30 -X POST \
      -H "Content-Type: application/json" \
      -H "X-GitHub-Event: push" \
      -H "X-Hub-Signature-256: sha256=$signature" \
      --data-binary "@$PAYLOAD_FILE" \
      "$DOCO_CD_URL/v1/webhook/$target" >/dev/null; then
    echo "doco-cd target $target: accepted"
  else
    echo "doco-cd target $target: failed" >&2
    failed=1
  fi
done
exit "$failed"
