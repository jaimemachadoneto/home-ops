# Homelab backlog

Open work from the backup, Ceph and SSO review of 2026-10-06, most important
first. What was done that day is summarised at the bottom.

## Next up

### 1. Off-site copy and NAS protection (backups) — highest risk

Every backup (Kopia repository, Postgres archive, Proxmox vzdump) lives on the
one TrueNAS box (2-disk mirror). Losing it, or ransomware/deletion through
NFS/S3, loses live data and backups together. Steps in
[offsite-backup.md](offsite-backup.md):

- [ ] TrueNAS: periodic ZFS snapshots of `Data1` (hourly kept 2 days, daily kept
      30 days). Five minutes, and protects against deletion from clients.
- [ ] Size the off-site copy: `du -sh` of `/mnt/Data1/kubernetes`,
      `/mnt/Data1/Documents`, the MinIO data path and the vzdump path.
- [ ] Cloudflare R2 bucket + TrueNAS Cloud Sync tasks (nightly, after Kopia
      maintenance at 03:30). Encryption passwords in 1Password.
- [ ] Restore one folder from R2 to prove it works.

### 2. Rotate credentials pasted into chat

- [ ] MQTT password (user `jaime` on `mqtt.jaimenet.com`, used by Frigate).
- [ ] Camera RTSP user (`bot`) on the three Reolink cameras.
- [ ] Then move Frigate's secrets out of `config.yaml` on the NAS: Frigate
      reads `{FRIGATE_*}` environment variables, which can come from 1Password
      through an ExternalSecret (step towards Frigate's config in git).

### 3. Postgres: move backups to the Barman Cloud Plugin — before any operator upgrade

Restore-on-rebuild is done (2026-10-07, PR `feat/cnpg-restore-on-rebuild`):
`postgres16` bootstraps from `recovery` of `postgres16-v0`, and the rebuild
procedure (bump `serverName`, base backup, then move the recovery source) is
in [offsite-backup.md](offsite-backup.md) under "Restore procedures >
Postgres". The operator chart is pinned at `0.29.1` (operator 1.30.1).

Still open:

- [ ] **Barman Cloud Plugin.** Operator 1.31.0 removes the in-tree
      `barmanObjectStore` (the API server warns on every apply), so backups
      stop on the next operator upgrade. Until this is done, reject Renovate
      PRs for the `cloudnative-pg` chart. Steps: install the
      `plugin-barman-cloud` (cert-manager is already in the cluster); create
      an `ObjectStore` with today's `barmanObjectStore` settings; in
      `cluster16.yaml` replace `backup.barmanObjectStore` with `plugins:`
      (`barman-cloud.cloudnative-pg.io`, `isWALArchiver: true`, same
      `serverName: postgres16-v0` so the archive continues) and point
      `externalClusters` at the plugin; ScheduledBackup `method: plugin`;
      update `restore-test/` and the backup alerts if metric names change.
      Then unpin the chart. Re-run the restore drill afterwards.
- [ ] Smaller deprecation warnings from the same apply:
      `nodeMaintenanceWindow` → `spec.enablePDB`, and
      `monitoring.enablePodMonitor` → our own PodMonitor.

### 4. Monitoring gaps

- [ ] NAS node-exporter: Prometheus already scrapes `nas.jaimenet.com:9100`
      (`kube-prometheus-stack/app/scrapeconfigs/node-exporter.yaml`), only the
      exporter is missing, so `TargetDown` fires. Install it as a TrueNAS
      custom app: image `quay.io/prometheus/node-exporter`, host network,
      host path `/` mounted read-only at `/host`, args `--path.rootfs=/host`.
      Nothing to change in git; check `up{instance="nas.jaimenet.com:9100"}`
      turns 1 and `node_zfs_zpool_state` has values.
- [ ] Then add NAS pool health to the Home-Ops MQTT device
      (`kubernetes/apps/observability/ha-status/`), from
      `node_zfs_zpool_state`.
- [ ] Optional: smartctl-exporter on the NAS (`:9108`); its ScrapeConfig is
      written but commented out in `scrapeconfigs/kustomization.yaml`.
- [x] `osd.0` slow ops: checked 2026-10-07. Ceph is `HEALTH_OK`; the
      `BLUESTORE_SLOW_OP_ALERT` was latched from the 10-06 load and cleared
      ~07:00 (it stays raised 24 h after the last slow op). Write latency over
      6 h: home-ops-00 `sdc` 3.8 ms vs 2.8 / 1.7 ms on the others, so ~2x,
      no longer 5-7x. If the alert comes back, check the Proxmox host behind
      home-ops-00 (SMART/wear of the disks backing its VM, other VMs on them).

### 5. Envoy external gateway resilience (caused an HA outage)

`envoy-external` uses `externalTrafficPolicy: Local`; Cilium does not move the
L2 announcement of `10.30.50.200` when the announcing node loses its envoy pod.
On 2026-10-06 a Rook osd-prepare job preempted the envoy pod on home-ops-01
(93% CPU requested) and `ha.jaimenet.com` was down until the lease
`cilium-l2announce-network-envoy-external` was deleted.

- [ ] Give the envoy proxies a high `priorityClassName` (EnvoyProxy config).
- [ ] Look at CPU requests on home-ops-01.

### 6. SSO: native OIDC for apps with their own login

Forward auth is done (see below). Next is OIDC, same pattern as Paperless in
`kubernetes/apps/selfhosted/authentik/app/blueprints/oidc.yaml` (provider in
the blueprint, client ID/secret from the app's 1Password item via
`authentik-secret` and `!Env`):

- [ ] Grafana, Open WebUI, Karakeep, Audiobookshelf, Booklore, Actual, pgAdmin,
      Semaphore, qui. Needs client secrets created in 1Password first.
- [ ] Paperless: Authentik logins map to user `akadmin` (made superuser), not
      the original `jaime`. Optionally move the link to `jaime` and delete
      `akadmin`; decide what other Authentik users get (default group or no
      sign-up).
- [ ] qBittorrent: its `AuthSubnetWhitelist` (10.0.0.0/8) skips its own login
      for the whole LAN; narrow it to the pod network before giving its API an
      Authentik bypass like the other download apps.

### 7. Smaller items

- [ ] Frigate: notification links never expire (`notification_proxy_expire_after_seconds: 0`
      in the HA Frigate integration options); set e.g. 86400.
- [ ] Paperless: nightly `document_exporter` to `/data/nas/export` (plain-file
      copy of all documents, picked up by the R2 sync of `Documents`).
- [ ] Test a VolSync restore of one app (procedure in
      [offsite-backup.md](offsite-backup.md)); Postgres has been drilled, volsync not.
- [ ] Cleanup: dead "Completed" pods left by node shutdowns, unused secret
      `network/envoy-oidc-hmac`.

## Done on 2026-10-06

- **Backups**: Postgres backup alerts + restore drill (passed); volsync
  retention 24h/7d/2w; `just k8s snapshot` fixed; docs `offsite-backup.md`,
  `storage.md`.
- **Ceph**: hourly volsync burst no longer restarts `mon.g` (jitter 0-15 min,
  movers spread across control-plane nodes, caches rebalanced: home-ops-00
  `sdc` 80% → 3%); `rook-ceph-cluster` HelmRelease timeout 30m.
- **Home Assistant monitoring**: `ha-status` publishes a Home-Ops MQTT device
  (status via Last Will, backups, alerts, Postgres, Ceph); automations notify
  the phone when it goes offline or backups have a problem.
- **Cameras**: HA's Frigate integration uses `http://10.30.50.205:5000`;
  go2rtc aliases `garagem`/`entrada` (H.264 sub-streams, none for Escritorio:
  that camera limits sessions); WebRTC via hostPort 8555 on home-ops-03;
  dashboards use Advanced Camera Card (MSE through HA, ~1-2 s).
- **SSO**: forward auth on 31 apps ([authentik-sso.md](authentik-sso.md));
  API paths of the download apps bypass it for phone apps; Paperless OIDC
  provider restored; Authentik 2 server replicas; old OIDC gateway attempt and
  CORS proxy removed. Zigbee2MQTT UIs reach HA through hass_ingress panels
  (`configuration.yaml`), their hostnames stay behind Authentik.
