#!/usr/bin/env bash
# Usage: backup.sh <namespace> <app> [--postgres]
# Make a fresh backup before a merge that can change data:
#  - a VolSync snapshot, if a ReplicationSource <app> exists in <namespace>;
#  - with --postgres, a CNPG backup of postgres16, the same as the nightly one.
# A backup can take 30 minutes: run this script in the background, not in the foreground.
# Exit: 0 all backups complete, 1 a backup failed or did not complete in 30 minutes,
#       3 no data to copy, 4 the hourly VolSync schedule is possibly stopped, 64 wrong arguments.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_args $# 2 "backup.sh <namespace> <app> [--postgres]"
ns=$1 app=$2 postgres=${3:-}
stamp="renovate-$(date +%Y%m%d%H%M%S)"
did=0

# A manual trigger stops the hourly schedule, and Flux does not remove a field that
# another field manager set. So remove it on every exit, also on an interrupt.
trigger_set=0
clear_trigger() {
  [ "$trigger_set" = 1 ] || return 0
  if ! kubectl -n "$ns" patch replicationsource "$app" --type json \
    -p '[{"op":"remove","path":"/spec/trigger/manual"}]' >/dev/null; then
    echo "CAUTION: remove spec.trigger.manual from replicationsource $ns/$app by hand, or hourly backups stay stopped"
    return 1
  fi
  trigger_set=0
}
on_exit() {
  local code=$?
  clear_trigger || code=4
  rm -rf "$TMP"
  exit "$code"
}
trap on_exit EXIT
trap 'exit 1' INT TERM

if kubectl -n "$ns" get replicationsource "$app" >/dev/null 2>&1; then
  did=1
  trigger_set=1
  kubectl -n "$ns" patch replicationsource "$app" --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"$stamp\"}}}" >/dev/null
  log "VolSync $ns/$app: snapshot $stamp started"
  ok=0
  for _ in $(seq 1 120); do
    [ "$(kubectl -n "$ns" get replicationsource "$app" -o jsonpath='{.status.lastManualSync}')" = "$stamp" ] && { ok=1; break; }
    sleep 15
  done
  clear_trigger || exit 4
  [ "$ok" = 1 ] || { echo "VolSync $ns/$app: no snapshot after 30 minutes"; exit 1; }
  echo "VolSync $ns/$app: snapshot $stamp complete"
fi

if [ "$postgres" = "--postgres" ]; then
  did=1
  kubectl -n database apply -f - >/dev/null <<YAML
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
YAML
  log "CNPG backup $stamp started"
  phase=""
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
