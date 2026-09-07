#!/bin/sh
# Tars up the Semaphore SQLite DB, config and secrets, keeps 2 days locally
# and 14 days on the NAS (if the NFS backup mount is up).
set -eu

APP_DIR=/opt/semaphore
STAGE_DIR="$APP_DIR/backups"
NAS_DIR=/mnt/semaphore-backup
TS=$(date +%Y%m%d-%H%M%S)
ARCHIVE="semaphore-${TS}.tar.gz"

mkdir -p "$STAGE_DIR"
tar -czf "$STAGE_DIR/$ARCHIVE" -C "$APP_DIR" data config semaphore.env

if mountpoint -q "$NAS_DIR" 2>/dev/null; then
  cp "$STAGE_DIR/$ARCHIVE" "$NAS_DIR/"
  find "$NAS_DIR" -maxdepth 1 -name 'semaphore-*.tar.gz' -mtime +14 -delete
else
  echo "warning: $NAS_DIR not mounted, backup kept locally only" >&2
fi

find "$STAGE_DIR" -maxdepth 1 -name 'semaphore-*.tar.gz' -mtime +2 -delete
