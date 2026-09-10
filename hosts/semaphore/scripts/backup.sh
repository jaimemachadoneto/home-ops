#!/bin/sh
# Snapshot Semaphore's database and config, keeping recent copies locally and
# on the NAS when its export is mounted.
#
# Everything Semaphore cannot be rebuilt without lives in two files:
#   database.sqlite - projects, templates, schedules, and the encrypted keys
#   config.json     - including access_key_encryption, which decrypts them
# They are worthless apart, so they are always archived together.
set -eu

APP_DIR=/opt/semaphore
STAGE_DIR="$APP_DIR/backups"
NAS_DIR=/mnt/semaphore-backup
LOCAL_KEEP_DAYS=14
NAS_KEEP_DAYS=30

TS=$(date +%Y%m%d-%H%M%S)
ARCHIVE="semaphore-${TS}.tar.gz"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$STAGE_DIR"

# Semaphore holds the database open in WAL mode, so simply copying the file
# while the server runs can capture a torn set of pages, and any committed
# transaction still sitting in the -wal would be missing from the copy.
# SQLite's backup API takes a consistent snapshot of a live database; python3
# exposes it, which avoids installing the sqlite3 CLI just for this.
#
# The integrity check afterwards means a corrupt archive fails the backup now,
# loudly, rather than being discovered during a restore.
python3 - "$APP_DIR/database.sqlite" "$WORK/database.sqlite" <<'PY'
import sqlite3
import sys

src, dst = sys.argv[1], sys.argv[2]
source = sqlite3.connect("file:%s?mode=ro" % src, uri=True)
target = sqlite3.connect(dst)
with target:
    source.backup(target)
result = target.execute("PRAGMA integrity_check").fetchone()[0]
target.close()
source.close()
if result != "ok":
    sys.exit("snapshot failed integrity check: %s" % result)
PY

cp "$APP_DIR/config.json" "$WORK/config.json"

tar -czf "$STAGE_DIR/$ARCHIVE" -C "$WORK" database.sqlite config.json
# The archive contains the key that decrypts every stored secret.
chmod 600 "$STAGE_DIR/$ARCHIVE"

# The NAS copy is best-effort: the mount is an automount, so a NAS outage (or a
# missing export) must not fail the backup - the local copy still happened. The
# timeout keeps a hung mount from stalling the timer indefinitely.
if timeout 60 mountpoint -q "$NAS_DIR" 2>/dev/null; then
  cp "$STAGE_DIR/$ARCHIVE" "$NAS_DIR/"
  find "$NAS_DIR" -maxdepth 1 -name 'semaphore-*.tar.gz' -mtime "+$NAS_KEEP_DAYS" -delete
  echo "backed up to $NAS_DIR/$ARCHIVE"
else
  echo "warning: $NAS_DIR not mounted, backup kept locally only" >&2
fi

find "$STAGE_DIR" -maxdepth 1 -name 'semaphore-*.tar.gz' -mtime "+$LOCAL_KEEP_DAYS" -delete
echo "local copy: $STAGE_DIR/$ARCHIVE"
