# shellcheck shell=bash
# Shared setup for the renovate-merge scripts. Source it; do not run it.

set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPTS" rev-parse --show-toplevel)"
lib() { python3 "$SCRIPTS/renovate_lib.py" "$@"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# gh gets its credentials from the 1Password app. A bash script does not get the zsh
# wrapper of the user, so this function calls `op plugin run`.
gh() { op plugin run -- gh "$@"; }

# helm and yq are in the home-ops shell only.
tool() {
  if command -v "$1" >/dev/null 2>&1; then "$@"; else direnv exec "$ROOT" "$@"; fi
}

log() { printf '%s\n' "$*" >&2; }

# A wrong call must not look like a result of the script, so it has its own exit code.
need_args() {
  [ "$1" -ge "$2" ] || { log "usage: $3"; exit 64; }
}
