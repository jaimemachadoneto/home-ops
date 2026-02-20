# Storage Overview

## Storage Solutions

### EPHEMERAL (Talos VolumeConfig)
- **Type**: System-level ephemeral storage
- **Size**: 100GiB max per node
- **Location**: System disk partition (`/dev/sda4`) — selected via `diskSelector: match: system_disk`
- **Purpose**: Temporary pod storage, container images, ephemeral volumes
- **Persistence**: Data lost on node reboot/replacement

### local-hostpath (Talos UserVolumeConfig)
- **Type**: Local node storage partition
- **Size**: 150GiB (controlplane nodes)
- **Location**: Dedicated disk (`/dev/sdc1`) — selected via `diskSelector: match: "!system_disk && disk.size < 300000000000u"`, mounted at `/var/mnt/local-hostpath`
- **Purpose**: Backing storage for OpenEBS hostpath provisioner
- **Persistence**: Survives pod restarts but tied to specific node
- **Note**: Separated from system disk in Feb 2026 migration; previously shared `sda`

### openebs-hostpath (StorageClass)
- **Type**: Local hostpath provisioner
- **Backing**: `/var/mnt/local-hostpath` directory from above
- **Purpose**: Dynamic local PV provisioning for fast, node-local storage
- **Persistence**: Data persists but is **not replicated** (single node)
- **Risk**: Data lost if node fails — use only with apps that have backup (volsync) or are tolerant of data loss

### rook-ceph (StorageClasses)
| Class                      | Type      | Access | Replicas        |
| -------------------------- | --------- | ------ | --------------- |
| `ceph-block` (**default**) | RBD block | RWO    | 3x across hosts |
| `ceph-filesystem`          | CephFS    | RWX    | 3x across hosts |

- **Devices**: `/dev/sdb` on home-ops-00, home-ops-01, home-ops-02 (~350GiB each)
- **Persistence**: Survives node failures — production-grade HA storage

---

## Node Disk Layout

| Node        | Disk       | Partition | Size    | Role                 |
| ----------- | ---------- | --------- | ------- | -------------------- |
| home-ops-00 | `/dev/sda` | `sda4`    | ~105 GB | EPHEMERAL            |
| home-ops-00 | `/dev/sdb` | —         | ~350 GB | Ceph OSD             |
| home-ops-00 | `/dev/sdc` | `sdc1`    | ~150 GB | local-hostpath       |
| home-ops-01 | `/dev/sda` | `sda4`    | ~105 GB | EPHEMERAL            |
| home-ops-01 | `/dev/sdb` | —         | ~350 GB | Ceph OSD             |
| home-ops-01 | `/dev/sdc` | `sdc1`    | ~150 GB | local-hostpath       |
| home-ops-02 | `/dev/sda` | `sda4`    | ~105 GB | EPHEMERAL            |
| home-ops-02 | `/dev/sdb` | —         | ~350 GB | Ceph OSD             |
| home-ops-02 | `/dev/sdc` | `sdc1`    | ~150 GB | local-hostpath       |
| home-ops-03 | `/dev/sda` | —         | —       | System only (worker) |

---

## Service Storage Map

| Service                                      | Namespace             | Persistent Storage                    | Storage Class      | Volsync Backup     |
| -------------------------------------------- | --------------------- | ------------------------------------- | ------------------ | ------------------ |
| **actions-runner-controller (jmn)**          | actions-runner-system | PVC (config)                          | `openebs-hostpath` | No                 |
| **actions-runner-controller (jmn-home-ops)** | actions-runner-system | PVC (config)                          | `openebs-hostpath` | No                 |
| **cloudnative-pg**                           | database              | PVC (data)                            | `openebs-hostpath` | No                 |
| **pgadmin**                                  | database              | PVC (1Gi)                             | `ceph-block`       | Yes                |
| **autobrr**                                  | downloads             | PVC                                   | `ceph-block`       | Yes                |
| **bazarr**                                   | downloads             | PVC                                   | `ceph-block`       | Yes                |
| **cross-seed**                               | downloads             | PVC                                   | `ceph-block`       | Yes                |
| **maintainerr**                              | downloads             | PVC                                   | `ceph-block`       | Yes                |
| **mylar**                                    | downloads             | PVC                                   | `ceph-block`       | Yes                |
| **overseerr**                                | downloads             | PVC (15Gi cache)                      | `ceph-block`       | Yes                |
| **pinchflat**                                | downloads             | PVC                                   | `ceph-block`       | Yes                |
| **prowlarr**                                 | downloads             | PVC                                   | `ceph-block`       | Yes                |
| **qbittorrent**                              | downloads             | PVC (2Gi)                             | `ceph-block`       | Yes                |
| **qui**                                      | downloads             | PVC                                   | `ceph-block`       | Yes                |
| **radarr**                                   | downloads             | PVC                                   | `ceph-block`       | Yes                |
| **recyclarr**                                | downloads             | PVC                                   | `ceph-block`       | Yes                |
| **sabnzbd**                                  | downloads             | PVC (downloads)                       | `openebs-hostpath` | Yes                |
| **shelfmark**                                | downloads             | PVC                                   | `ceph-block`       | Yes                |
| **sonarr**                                   | downloads             | PVC                                   | `ceph-block`       | Yes                |
| **tautulli**                                 | downloads             | PVC (15Gi cache)                      | `ceph-block`       | Yes                |
| **frigate**                                  | home-automation       | PVC                                   | `ceph-block`       | No (commented out) |
| **audiobookshelf**                           | media                 | PVC                                   | `ceph-block`       | Yes                |
| **booklore**                                 | media                 | PVC                                   | `ceph-block`       | Yes                |
| **gatus**                                    | observability         | emptyDir only                         | —                  | No                 |
| **grafana**                                  | observability         | PVC                                   | `ceph-block`       | Yes                |
| **headlamp**                                 | observability         | emptyDir only                         | —                  | No                 |
| **kube-prometheus-stack**                    | observability         | PVC (Prometheus + Alertmanager)       | `ceph-block`       | No                 |
| **victoria-logs**                            | observability         | PVC                                   | `ceph-block`       | No                 |
| **onepassword-connect**                      | external-secrets      | emptyDir only                         | —                  | No                 |
| **actual**                                   | selfhosted            | PVC                                   | `ceph-block`       | Yes                |
| **argus**                                    | selfhosted            | PVC                                   | `ceph-block`       | Yes                |
| **atuin**                                    | selfhosted            | PVC (5Gi)                             | `ceph-block`       | Yes                |
| **filebrowser**                              | selfhosted            | PVC (5Gi, RWX)                        | `ceph-filesystem`  | No                 |
| **karakeep**                                 | selfhosted            | PVC                                   | `ceph-block`       | Yes                |
| **openwebui**                                | selfhosted            | PVC                                   | `ceph-block`       | Yes                |
| **paperless**                                | selfhosted            | PVC (15Gi data, 1Gi cache, 1Gi media) | `ceph-block`       | Yes                |
| **rclone (syncDocumentsJaime)**              | selfhosted            | NFS (10.30.10.11)                     | NFS direct         | No                 |
| **rclone (syncDocumentsMonica)**             | selfhosted            | NFS (10.30.10.11)                     | NFS direct         | No                 |
| **rclone (syncPaperlessOcr)**                | selfhosted            | NFS (10.30.10.11)                     | NFS direct         | No                 |
| **searxng**                                  | selfhosted            | emptyDir only                         | —                  | No                 |
| **kopia**                                    | system                | emptyDir (temp)                       | —                  | No                 |
| **volsync**                                  | system                | — (backup system itself)              | —                  | —                  |

---

## Volsync Backup Details

- **Schedule**: Hourly
- **Destination**: NAS at `nas.internal:/mnt/Data1/kubernetes`
- **Method**: Kopia (via restic-compatible snapshots)
- **Retention**: 24 hourly, 7 daily
- **Cache StorageClass**: `openebs-hostpath` (fast local cache during backup/restore jobs)
- **Default PVC StorageClass**: `ceph-block`
- **Snapshot Class**: `csi-ceph-blockpool`

---

## Post-Node-Reset Cleanup

After resetting/replacing a Talos node, `openebs-hostpath` PVs that were pinned to that node will point to paths that no longer exist on the new disk. The following resources must be manually recycled.

**Affected resources (per node reset):**
- Ceph mon PVC (`rook-ceph/rook-ceph-mon-<id>`)
- Postgres replica PVC (`database/postgres16-<N>`)
- All `volsync-src-*-cache` PVCs pinned to that node

**Cleanup procedure for each stale PVC:**
```bash
VOL=$(kubectl -n <ns> get pvc <name> -o jsonpath='{.spec.volumeName}')
kubectl -n <ns> delete pod <pod> --force --grace-period=0
kubectl -n <ns> patch pvc <name> -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl -n <ns> delete pvc <name>
kubectl delete pv "$VOL"
```

**Bulk cleanup for volsync cache PVCs** — pause first to stop respawning:
```bash
# 1. Pause all ReplicationSources
kubectl get replicationsource -A -o json | \
  python3 -c "import json,sys; data=json.load(sys.stdin)
[print(i['metadata']['namespace'], i['metadata']['name']) for i in data['items']]" | \
  while read ns name; do
    kubectl -n "$ns" patch replicationsource "$name" --type=merge -p '{"spec":{"paused":true}}'
  done

# 2. Delete stale PVCs/PVs (replace <reset-node> with e.g. home-ops-01)
kubectl get pv -o json | python3 -c "
import json,sys; data=json.load(sys.stdin)
for item in data['items']:
    if item['spec'].get('storageClassName') != 'openebs-hostpath': continue
    me = item['spec'].get('nodeAffinity',{}).get('required',{}).get('nodeSelectorTerms',[{}])[0]
    node = me.get('matchExpressions',[{}])[0].get('values',['?'])[0]
    if node != '<reset-node>': continue
    c = item['spec'].get('claimRef',{})
    if 'cache' in c.get('name',''): print(c['namespace'], c['name'], item['metadata']['name'])
" | while read ns pvc pv; do
  kubectl -n "$ns" patch pvc "$pvc" -p '{"metadata":{"finalizers":[]}}' --type=merge
  kubectl -n "$ns" delete pvc "$pvc" --ignore-not-found --wait=false
  kubectl delete pv "$pv" --ignore-not-found --wait=false
done

# 3. Unpause all ReplicationSources
kubectl get replicationsource -A -o json | \
  python3 -c "import json,sys; data=json.load(sys.stdin)
[print(i['metadata']['namespace'], i['metadata']['name']) for i in data['items']]" | \
  while read ns name; do
    kubectl -n "$ns" patch replicationsource "$name" --type=merge -p '{"spec":{"paused":false}}'
  done
```

**Other post-reset tips:**
- **Rook mon stuck ~10 min** — skip the 600s failover wait: `kubectl -n rook-ceph delete deployment rook-ceph-mon-<id>`
- **CNPG postgres switchover** (no kubectl-cnpg plugin needed): `kubectl -n database patch cluster postgres16 --type merge --subresource=status -p '{"status":{"targetPrimary":"<pod-name>"}}'`
- **Stale RBD watchers** after force-deleting pods (kernel mount not cleaned up): `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd blacklist add <ip>:0/<nonce>` then `ceph osd blacklist rm <ip>:0/<nonce>` once pods are running on the new node
- **Stale VolumeAttachments**: `kubectl get volumeattachment` — delete any still pointing to the reset node after pods are force-deleted
