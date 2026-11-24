#!/bin/sh
# Runs in the container `state-sync`. Each hour it copies the text
# configuration of each Hermes profile to the private repository
# jaimemachadoneto/hermes-state, so that Jaime can read it and its history
# outside the cluster. It is a view and a copy, not a source: nothing reads
# it back. The full backup of the volume is volsync.
set -u

DATA=/opt/data
REPO=/work/repo
URL=https://github.com/jaimemachadoneto/hermes-state.git
# The token stays in its file. git reads it through this helper on each push,
# and gives it to github.com only.
HELPER='!f() { echo username=x-access-token; printf "password="; cat /mnt/secrets/state-sync/token; }; f'
CRED=credential.https://github.com.helper
# A commit with one of these patterns is not pushed. .env, auth.json and the
# databases are never copied, but a key can still be typed into config.yaml
# or a memory.
SECRET_PATTERN='sk-ant-|sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_|ops_[A-Za-z0-9]{20,}|xox[abp]-|xapp-|eyJ[A-Za-z0-9_-]{20,}|[Bb]earer +[A-Za-z0-9._-]{20,}|AKIA[0-9A-Z]{16}|PRIVATE KEY-----'

g() { git -C "$REPO" -c "$CRED=$HELPER" "$@"; }

# copy_home SOURCE TARGET: only the text files of one profile.
copy_home() {
  rm -rf "$2"
  mkdir -p "$2"
  # -P copies a symbolic link as a link. An agent can write on the volume,
  # and a link to the token file must not copy the token.
  for f in config.yaml SOUL.md cron/jobs.json; do
    if [ -f "$1/$f" ]; then mkdir -p "$2/$(dirname "$f")"; cp -P "$1/$f" "$2/$f"; fi
  done
  for d in memories skills; do
    [ -d "$1/$d" ] && cp -RP "$1/$d" "$2/$d"
  done
  # Only the skills that the agent wrote: the bundled skills are the same in
  # each image and have example tokens that the secret check refuses. The
  # dot entries (hub cache, usage, locks) are runtime state.
  if [ -d "$2/skills" ]; then
    if [ -f "$1/skills/.bundled_manifest" ]; then
      cut -d: -f1 "$1/skills/.bundled_manifest" | while read -r s; do
        [ -n "$s" ] && find "$2/skills" -mindepth 1 -maxdepth 3 -type d -name "$s" -exec rm -rf {} +
      done
    fi
    find "$2/skills" -mindepth 1 -maxdepth 1 -name '.*' -exec rm -rf {} +
    find "$2/skills" -type d -empty -delete
  fi
  # The lock files of memories change on each write and hold nothing. Links,
  # nested repositories and large files are not configuration.
  find "$2" -name '*.lock' -delete
  find "$2" -type l -delete
  find "$2" -name '.git*' -prune -exec rm -rf {} +
  find "$2" -type f -size +1024k -delete
}

sync_once() {
  if [ ! -d "$REPO/.git" ]; then
    git -c "$CRED=$HELPER" clone -q "$URL" "$REPO" || return 1
  fi
  g pull -q --ff-only 2>/dev/null || true
  copy_home "$DATA" "$REPO/default"
  rm -rf "$REPO/profiles"
  # No dollar-brace expansion in this file: Flux substitutes it in the ConfigMap.
  for p in "$DATA"/profiles/*; do
    [ -d "$p" ] && [ ! -L "$p" ] && copy_home "$p" "$REPO/profiles/$(basename "$p")"
  done
  g add -A
  g diff --cached --quiet && return 0
  # --text: git prints no content for a binary file, so the scan would miss it.
  if g diff --cached --text | grep -qE "$SECRET_PATTERN"; then
    echo "state-sync: a possible secret is in the change; nothing is pushed" >&2
    g reset -q
    return 1
  fi
  g commit -qm "Snapshot $(date -u +%Y-%m-%dT%H:%MZ)" && g push -q origin HEAD
}

git config --global user.name "hermes-state-sync"
git config --global user.email "hermes-state-sync@users.noreply.github.com"
git config --global init.defaultBranch main
while true; do
  sync_once || echo "state-sync: the sync failed; next try in 1 hour" >&2
  sleep 3600
done
