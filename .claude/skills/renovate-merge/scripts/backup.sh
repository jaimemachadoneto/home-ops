#!/usr/bin/env bash
# Usage: backup.sh <namespace> <app> [--postgres]
# Make a fresh backup before a merge that can change data:
#  - a VolSync snapshot, if a ReplicationSource <app> exists in <namespace>;
#  - with --postgres, a CNPG backup of postgres16, the same as the nightly one.
# Exit: 0 all backups complete, 1 a backup failed or timed out, 3 no data to copy.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ns=$1 app=$2 postgres=${3:-}
stamp="renovate-$(date +%Y%m%d%H%M%S)"
did=0

if kubectl -n "$ns" get replicationsource "$app" >/dev/null 2>&1; then
  did=1
  kubectl -n "$ns" patch replicationsource "$app" --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"$stamp\"}}}" >/dev/null
  log "VolSync $ns/$app: snapshot $stamp started"
  ok=0
  for _ in $(seq 1 120); do
    [ "$(kubectl -n "$ns" get replicationsource "$app" -o jsonpath='{.status.lastManualSync}')" = "$stamp" ] && { ok=1; break; }
    sleep 15
  done
  # A manual trigger can stop the hourly schedule; Flux would restore it later, but do not wait.
  kubectl -n "$ns" patch replicationsource "$app" --type json -p '[{"op":"remove","path":"/spec/trigger/manual"}]' >/dev/null || true
  [ "$ok" = 1 ] || { echo "VolSync $ns/$app: no snapshot after 30 minutes"; exit 1; }
  echo "VolSync $ns/$app: snapshot $stamp complete"
fi

if [ "$postgres" = "--postgres" ]; then
  did=1
  kubectl -n database apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $stamp
spec:
  cluster:
    name: postgres16
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
  log "CNPG backup $stamp started"
  for _ in $(seq 1 120); do
    phase=$(kubectl -n database get backup "$stamp" -o jsonpath='{.status.phase}')
    case $phase in
      completed) echo "CNPG backup $stamp complete"; break ;;
      failed) echo "CNPG backup $stamp failed"; exit 1 ;;
    esac
    sleep 15
  done
  [ "$phase" = completed ] || { echo "CNPG backup $stamp: no result after 30 minutes"; exit 1; }
fi

[ "$did" = 1 ] || { echo "nothing to back up for $ns/$app"; exit 3; }
