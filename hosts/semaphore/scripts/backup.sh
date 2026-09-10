#!/bin/sh
# Snapshot Semaphore's database and config, keeping recent copies locally and
# on the NAS when its export is mounted.
#
# Everything Semaphore cannot be rebuilt without:
#   data/database.db  - projects, templates, schedules, and the encrypted keys
#   config/config.json - including access_key_encryption, which decrypts them
#   semaphore.env      - the same key plus the admin password, as compose reads it
# The database and the key are worthless apart, so they are archived together.
set -eu

APP_DIR=/opt/semaphore
DB_FILE="$APP_DIR/data/database.db"
CONFIG_FILE="$APP_DIR/config/config.json"
ENV_FILE="$APP_DIR/semaphore.env"
STAGE_DIR="$APP_DIR/backups"
NAS_DIR=/mnt/semaphore-backup
LOCAL_KEEP_DAYS=14
NAS_KEEP_DAYS=30

TS=$(date +%Y%m%d-%H%M%S)
ARCHIVE="semaphore-${TS}.tar.gz"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$STAGE_DIR"

# The native install kept its database elsewhere. If the expected file is gone,
# fail rather than quietly producing an archive of whatever is left behind.
[ -f "$DB_FILE" ] || { echo "no database at $DB_FILE" >&2; exit 1; }
[ -f "$CONFIG_FILE" ] || { echo "no config at $CONFIG_FILE" >&2; exit 1; }

# Semaphore holds the database open in WAL mode, so simply copying the file
# while the server runs can capture a torn set of pages, and any committed
# transaction still sitting in the -wal would be missing from the copy.
# SQLite's backup API takes a consistent snapshot of a live database; python3
# exposes it, which avoids installing the sqlite3 CLI just for this.
#
# The integrity check afterwards means a corrupt archive fails the backup now,
# loudly, rather than being discovered during a restore.
python3 - "$DB_FILE" "$WORK/database.db" <<'PY'
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

cp "$CONFIG_FILE" "$WORK/config.json"
[ -f "$ENV_FILE" ] && cp "$ENV_FILE" "$WORK/semaphore.env"

tar -czf "$STAGE_DIR/$ARCHIVE" -C "$WORK" .
# The archive contains the key that decrypts every stored secret.
chmod 600 "$STAGE_DIR/$ARCHIVE"

# The NAS copy is best-effort: the mount is an automount, so a NAS outage (or a
# missing export) must not fail the backup - the local copy still happened. The
# timeout keeps a hung mount from stalling the timer indefinitely.
#
# Copy to $NAS_DIR when something is mounted there. Nothing is, by design:
# offsite copies are Proxmox's job (vzdump of the whole container), and an
# unprivileged LXC cannot mount NFS itself. This still fires if a PVE bind
# mount is ever attached at that path, which is the supported way to give this
# container a share directly.
#
# The explicit mount covers an fstab entry existing: systemd refuses automount
# units inside a container, so x-systemd.automount silently does nothing and a
# share would otherwise never be mounted on an unattended run.
if ! mountpoint -q "$NAS_DIR" 2>/dev/null; then
  timeout 60 mount "$NAS_DIR" >/dev/null 2>&1 || true
fi

if timeout 60 mountpoint -q "$NAS_DIR" 2>/dev/null; then
  cp "$STAGE_DIR/$ARCHIVE" "$NAS_DIR/"
  find "$NAS_DIR" -maxdepth 1 -name 'semaphore-*.tar.gz' -mtime "+$NAS_KEEP_DAYS" -delete
  echo "backed up to $NAS_DIR/$ARCHIVE"
else
  echo "no share mounted at $NAS_DIR; local copy only (offsite is vzdump's job)"
fi

find "$STAGE_DIR" -maxdepth 1 -name 'semaphore-*.tar.gz' -mtime "+$LOCAL_KEEP_DAYS" -delete
echo "local copy: $STAGE_DIR/$ARCHIVE"
