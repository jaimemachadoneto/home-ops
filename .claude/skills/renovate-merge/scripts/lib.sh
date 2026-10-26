# shellcheck shell=bash
# Shared setup for the renovate-merge scripts. Source it; do not run it.

set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPTS" rev-parse --show-toplevel)"
lib() { python3 "$SCRIPTS/renovate_lib.py" "$@"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# gh logs in through the 1Password app. A bash script does not get the zsh wrapper.
gh() { op plugin run -- gh "$@"; }

# helm and yq are in the home-ops shell only.
tool() {
  if command -v "$1" >/dev/null 2>&1; then "$@"; else direnv exec "$ROOT" "$@" 2>/dev/null; fi
}

log() { printf '%s\n' "$*" >&2; }
