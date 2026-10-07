# Backups: layout, off-site copy, and restore

## Where data lives today

| Data | Backed up by | Lands on | Retention |
| --- | --- | --- | --- |
| App PVCs (26 apps, see `docs/storage.md`) | VolSync + Kopia, hourly | NAS `/mnt/Data1/kubernetes` (NFS) | 24h / 7d / 2w |
| Postgres `postgres16` | Barman Cloud plugin (ObjectStore `postgres16-nas`): WAL continuously, base backup daily | NAS MinIO, `s3://cloudnative/postgres16-v0` | 31d |
| Semaphore LXC | `hosts/semaphore/scripts/backup.sh` + Proxmox vzdump | NAS | 14d local |
| Documents, scans | rclone jobs + Paperless | NAS `/mnt/Data1/Documents` | none |
| Keys (Kopia password, S3 keys, Talos secrets, age key) | 1Password | off-site | — |

The NAS is TrueNAS on a two-disk mirror. The mirror protects against a single
disk failing, and nothing else: losing the NAS, ransomware, or a bad delete
over NFS/S3 takes the live data and every backup with it. The two steps below
close that gap.

## Step 1: ZFS snapshots on TrueNAS

Snapshots are read-only from NFS and S3 clients, so a compromised client, a
bad Kopia prune or a cluster bug cannot remove them.

**Data Protection → Periodic Snapshot Tasks → Add**, for dataset `Data1`,
recursive:

| Task | Schedule | Keep |
| --- | --- | --- |
| hourly | every hour | 2 days |
| daily | 00:00 | 30 days |

While there, check that a scrub task and SMART tests are scheduled and that
TrueNAS alerts reach you (System → Alert Settings).

## Step 2: nightly off-site copy to Cloudflare R2

R2's free tier is 10 GB-month of storage, 1M Class A and 10M Class B
operations a month, and no egress fees, so restoring costs nothing. Past the
free tier storage is about $0.015 per GB-month. Size the copy first, in the
TrueNAS shell:

```bash
du -sh /mnt/Data1/kubernetes /mnt/Data1/Documents <minio-data-path> <vzdump-path>
```

### R2 side

1. Cloudflare dashboard → R2 → create bucket `home-ops-offsite`.
2. R2 → Manage API tokens → create a token with **Object Read & Write** on
   that bucket only.
3. Save the access key ID, secret and the endpoint
   (`https://<account-id>.r2.cloudflarestorage.com`) in 1Password as
   `r2-offsite`.

### TrueNAS side

1. **Credentials → Backup Credentials → Cloud Credentials → Add**: provider
   *Amazon S3*, endpoint URL from above, region `auto`, the R2 key pair.
2. **Data Protection → Cloud Sync Tasks → Add**, one task per source:

| Source | Bucket folder | Remote encryption |
| --- | --- | --- |
| `/mnt/Data1/kubernetes` | `kopia/` | off (Kopia already encrypts) |
| MinIO data path of bucket `cloudnative` | `cnpg/` | **on** |
| vzdump path | `vzdump/` | **on** |
| `/mnt/Data1/Documents` | `documents/` | **on** |

   For each task: direction **PUSH**, transfer mode **SYNC**, tick
   **Take Snapshot** (uploads from a consistent ZFS snapshot), schedule
   **04:30 daily** (after Kopia maintenance at 03:30 and the CNPG daily
   backup).
3. Remote encryption uses rclone crypt. Store the encryption password and
   salt in 1Password (`r2-offsite`): without them the R2 copy is unreadable.
4. Run each task once by hand and check the R2 bucket shows the folders.

If the copy is well over 10 GB, vzdump is usually the bulk of it: send only
the newest dump, or only the Semaphore LXC's.

### Known limitation

SYNC mirrors deletions, so a compromised NAS can empty the R2 copy on its
next run. The ZFS snapshots from step 1 cover most of that risk. R2 bucket
lock rules would block deletes for N days but make SYNC fail when Kopia prunes
old blobs; revisit if needed.

## Step 3: dead man's switch in Home Assistant

Every backup alert depends on Prometheus and Alertmanager running. To catch
those, or the whole cluster, going quiet, `ha-status`
(`kubernetes/apps/observability/ha-status/`) publishes a **Home-Ops** device
to Home Assistant through MQTT discovery (`mqtt.jaimenet.com`), refreshed
every minute:

| Entity | Shows |
| --- | --- |
| `binary_sensor.home_ops_status` | connected; **unavailable** means the cluster side is down |
| `binary_sensor.home_ops_backup_problem` | on when a VolSync app is out of sync or Postgres backups/WAL are late (reasons in attributes) |
| `sensor.home_ops_critical_alerts` | critical alerts firing (names in attributes) |
| `sensor.home_ops_volsync_out_of_sync` | apps whose backup is overdue (names in attributes) |
| `sensor.home_ops_postgres_backup_age` | hours since the last Postgres base backup |
| `sensor.home_ops_postgres_wal_age` | minutes since the last WAL archive |
| `sensor.home_ops_nodes_ready` | ready nodes (total in attributes) |
| `sensor.home_ops_ceph_health` | `HEALTH_OK` / `HEALTH_WARN` / `HEALTH_ERR` |
| `binary_sensor.home_ops_nas_problem` | on when a NAS ZFS pool is not `online`, `Data1` is over 90% full, or the NAS node-exporter is unreachable (reasons and pool states in attributes) |
| `sensor.home_ops_nas_data_used` | `Data1` used, % (all datasets, snapshots not included) |
| `binary_sensor.home_ops_prometheus`, `..._alertmanager`, `sensor.home_ops_last_update` | diagnostics |

It follows Home Assistant's MQTT conventions: one retained device discovery
config, an availability topic (`home-ops/availability`) backed by an MQTT
Last Will, and a fresh announcement whenever Home Assistant restarts (birth
message on `homeassistant/status`). When the pod, its node, the cluster or the
network dies, the broker publishes the will within about 90 seconds and every
entity turns unavailable. Home Assistant automations notify on
`binary_sensor.home_ops_status` being unavailable and on
`binary_sensor.home_ops_backup_problem` turning on. The MQTT login comes from
the 1Password item `mqtt` (`mqtt_username`, `mqtt_password`).

## NAS monitoring

node-exporter runs on TrueNAS as a custom app (Apps → Discover Apps → ⋮ →
Install via YAML, name `node-exporter`):

```yaml
services:
  node-exporter:
    image: quay.io/prometheus/node-exporter:v1.12.1
    command:
      - --path.rootfs=/host
    network_mode: host
    pid: host
    restart: unless-stopped
    volumes:
      - /:/host:ro,rslave
```

Prometheus scrapes `nas.jaimenet.com:9100`
(`kube-prometheus-stack/app/scrapeconfigs/node-exporter.yaml`);
`ZfsUnexpectedPoolState` alerts on a pool that is not `online`.

## Dashboards

- **Home Assistant**: dashboard *Home-Ops* (`/home-ops`, admins only), built
  from the Home-Ops device: cluster, backups, NAS, 48 h history, links to
  Grafana and Alertmanager. It lives in Home Assistant's storage, not git.
- **Grafana**: *Home-Ops: backups & storage* (`/d/home-ops-backups`), from
  `kubernetes/apps/observability/grafana/app/dashboard/home-ops.json`:
  the same signals plus history: Postgres backup/WAL age and connections per
  role, VolSync backup durations, NAS pools, Data1 usage and largest datasets,
  NAS disk throughput, Ceph usage and OSD latency. The NAS host itself is in
  *Node Exporter Full* (instance `nas.jaimenet.com:9100`).

## Restore procedures

### One app from VolSync

The volsync component fills a new PVC from the `<app>-bootstrap`
ReplicationDestination's latest image. That image is from whenever the
bootstrap last ran, so run a fresh restore first, then recreate the PVC:

```bash
# 1. Stop the app and its hourly backup (a backup of a half-restored volume is worse than none)
flux suspend kustomization <app> -n flux-system
kubectl -n <ns> patch replicationsource <app> --type merge -p '{"spec":{"paused":true}}'
kubectl -n <ns> scale deploy/<app> --replicas 0        # or the app's controller

# 2. Pull the latest backup into a fresh snapshot, and wait for it
T="restore-$(date +%s)"
kubectl -n <ns> patch replicationdestination <app>-bootstrap --type merge \
  -p "{\"spec\":{\"trigger\":{\"manual\":\"$T\"}}}"
until [ "$(kubectl -n <ns> get replicationdestination <app>-bootstrap -o jsonpath='{.status.lastManualSync}')" = "$T" ]; do sleep 10; done

# 3. Replace the PVC; Flux recreates it from that snapshot
kubectl -n <ns> delete pvc <claim>
flux resume kustomization <app> -n flux-system
kubectl -n <ns> patch replicationsource <app> --type merge -p '{"spec":{"paused":false}}'
```

To restore an older snapshot instead of the latest, set
`spec.kopia.restoreAsOf` (an RFC 3339 time) on the ReplicationDestination
before step 2. Field support varies between volsync builds, so confirm it with
`kubectl explain replicationdestination.spec.kopia` first.

Browse snapshots and restore single files from the Kopia UI
(`kopia.${SECRET_DOMAIN}`).

### Postgres

`postgres16` is bootstrapped with `recovery` from its own archive
(`cluster16.yaml`), so a new or re-created cluster restores the latest backup
plus WAL instead of starting empty, and fails to start if it cannot read the
archive. The restore drill (`restore-test/`, see `docs/cnpg-backup-review.md`)
exercises the same path without touching production.

Two names matter, both in `cluster16.yaml`:

| Field | Meaning | Today |
| --- | --- | --- |
| `plugins[barman-cloud].parameters.serverName` | archive the running cluster writes to | `postgres16-v0` |
| `bootstrap.recovery.source` (and the `externalClusters` entry) | archive a new cluster restores from | `postgres16-v0` |

They are equal while the cluster runs. CNPG refuses to archive into a path
that already holds another cluster's backups ("Expected empty archive"), so a
re-created cluster needs the write name bumped.

**Rebuilding on purpose** (corrupt data, lost PVCs on both nodes, a
re-bootstrap):

1. Commit: `serverName: postgres16-v1`; leave `recovery.source` at
   `postgres16-v0`. Merge and let Flux apply it.
2. Delete the cluster; CNPG removes its PVCs, Flux re-creates it and it
   restores from `v0`:

   ```bash
   kubectl -n database delete cluster postgres16
   kubectl -n database get cluster postgres16 -w     # until "Cluster in healthy state"
   ```

3. Take a base backup in the new archive straight away (the daily
   ScheduledBackup only runs at midnight):

   ```bash
   kubectl -n database create -f - <<'YAML'
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata:
     generateName: postgres16-rebuild-
   spec:
     cluster:
       name: postgres16
     method: plugin
     pluginConfiguration:
       name: barman-cloud.cloudnative-pg.io
   YAML
   ```

4. Commit: `recovery.source` (and the `restore-test` source, and the
   archive path in the table at the top) to `postgres16-v1`, so the next
   rebuild restores from the new archive. **Do not skip this**: a rebuild from
   `v0` later would lose everything written since step 2.
5. After 31 days, once `v1` holds a full retention window, delete
   `s3://cloudnative/postgres16-v0/` from MinIO (retention only prunes the
   archive the cluster writes to).

**Re-created by accident** (namespace deleted, Cluster pruned): it restores
from `v0` by itself, then WAL archiving fails and the Postgres backup alerts
fire (also `binary_sensor.home_ops_backup_problem` in Home Assistant). The
data is safe, but WAL piles up in `pg_wal` until archiving works again, so do
steps 1, 3 and 4 above the same day. Changing `serverName` on the running
cluster only re-points the archiver; it does not re-create anything.

### From R2 (NAS lost)

1. Rebuild the NAS, recreate the datasets.
2. TrueNAS Cloud Sync task with direction **PULL** per folder (same
   credentials and encryption password from 1Password).
3. Kopia repo back at `/mnt/Data1/kubernetes` and the MinIO bucket restored:
   the cluster's normal restore paths then work unchanged.

## Test schedule

| What | How often |
| --- | --- |
| Restore one app's PVC into a scratch namespace | quarterly |
| CNPG restore drill (`restore-test/`) | quarterly |
| Pull one folder back from R2 and open a few files | twice a year |
