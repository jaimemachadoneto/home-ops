#!/bin/sh
# Bootstrap Semaphore + its doco-cd GitOps deployer on a bare Debian/Raspberry
# Pi host. Idempotent: safe to re-run (e.g. after a fresh SD card flash).
#
# What this does NOT do: deploy the Semaphore container itself. Once doco-cd
# is running and its deploy key is registered on GitHub, doco-cd polls this
# repo and runs `docker compose up` for hosts/semaphore on its own - see
# README.md.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
APP_DIR=/opt/semaphore
DOCO_CD_DIR=/opt/doco-cd
CONTAINER_UID=1001

if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker Engine + compose plugin..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker.io docker-compose
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$(whoami)"
  echo "Added $(whoami) to the docker group - log out/in (or re-ssh) before running this again if 'docker ps' below fails."
fi

# --- Semaphore app directories -----------------------------------------
sudo mkdir -p "$APP_DIR/data" "$APP_DIR/config" "$APP_DIR/tmp" "$APP_DIR/backups"
# Container runs as uid 1001 (non-root); it needs to write config.json into
# /etc/semaphore, its DB into /var/lib/semaphore, and playbook tmp files.
sudo chown -R "${CONTAINER_UID}:${CONTAINER_UID}" "$APP_DIR/data" "$APP_DIR/config" "$APP_DIR/tmp"
sudo chown "$(whoami)" "$APP_DIR/backups"

if [ ! -f "$APP_DIR/semaphore.env" ]; then
  echo "Generating admin password + access key encryption secret..."
  ADMIN_PW=$(openssl rand -base64 18)
  ENC_KEY=$(openssl rand -base64 32)
  umask 077
  cat > "$APP_DIR/semaphore.env" <<EOF
SEMAPHORE_ADMIN_PASSWORD=${ADMIN_PW}
SEMAPHORE_ACCESS_KEY_ENCRYPTION=${ENC_KEY}
EOF
  echo "Admin login: admin / ${ADMIN_PW}  (also saved in $APP_DIR/semaphore.env)"
fi
# semaphore.env is read by docker-compose on the host, not by the container,
# so it must stay owned by the invoking user, NOT the container uid above.

mkdir -p "$APP_DIR/scripts"
cp "$SCRIPT_DIR/scripts/backup.sh" "$APP_DIR/scripts/backup.sh"
chmod +x "$APP_DIR/scripts/backup.sh"

# --- Backups (NFS mount to NAS + daily timer) ---------------------------
# Requires 10.30.50.210 (this Pi) to be allowed read-write on the NAS export
# for /mnt/Data1/semaphore - see README.md if the mount stays empty/RO.
sudo apt-get install -y -qq nfs-common
sudo mkdir -p /mnt/semaphore-backup
if ! grep -q '/mnt/semaphore-backup' /etc/fstab; then
  echo "nas.jaimenet.com:/mnt/Data1/semaphore /mnt/semaphore-backup nfs4 _netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=600,timeo=30,retrans=2 0 0" | sudo tee -a /etc/fstab >/dev/null
fi
sudo systemctl daemon-reload

sudo cp "$SCRIPT_DIR/systemd/semaphore-backup.service" "$SCRIPT_DIR/systemd/semaphore-backup.timer" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now semaphore-backup.timer

# --- doco-cd (GitOps deployer) ------------------------------------------
sudo mkdir -p "$DOCO_CD_DIR/data"
sudo chown -R "$(whoami)" "$DOCO_CD_DIR"

if [ ! -f "$DOCO_CD_DIR/deploy_key" ]; then
  echo "Generating a read-only deploy key for doco-cd..."
  ssh-keygen -t ed25519 -N "" -C "doco-cd@$(hostname)" -f "$DOCO_CD_DIR/deploy_key"
  echo
  echo "=================================================================="
  echo "Add this PUBLIC key as a READ-ONLY deploy key on the home-ops repo:"
  echo "  https://github.com/jaimemachadoneto/home-ops/settings/keys"
  echo "  (or: gh repo deploy-key add \"$DOCO_CD_DIR/deploy_key.pub\" --title doco-cd-$(hostname) --repo jaimemachadoneto/home-ops)"
  echo
  cat "$DOCO_CD_DIR/deploy_key.pub"
  echo "=================================================================="
  echo
fi

cp "$SCRIPT_DIR/doco-cd/poll-config.yml" "$DOCO_CD_DIR/data/poll-config.yml"
cp "$SCRIPT_DIR/doco-cd/docker-compose.yml" "$DOCO_CD_DIR/docker-compose.yml"

cd "$DOCO_CD_DIR"
docker compose up -d

echo
echo "doco-cd is running and will deploy/update Semaphore from git within its"
echo "poll interval (5m) once the deploy key above is registered on GitHub."
echo "Check progress with: docker logs -f doco-cd"
