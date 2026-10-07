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

### 3. NAS: Data1 is 87% full

node-exporter runs on the NAS since 2026-10-07 (TrueNAS custom app, YAML in
[offsite-backup.md](offsite-backup.md)); Prometheus scrapes it,
`ZfsUnexpectedPoolState` covers pool health and Home Assistant shows
`binary_sensor.home_ops_nas_problem` / `sensor.home_ops_nas_data_used`.

- [ ] `Data1`: 3,133 GiB used, 463 GiB free (87%, snapshots not counted),
      2.9 TiB of it `MediaServer`. ZFS slows down past ~80-90% and the
      periodic snapshots from item 1 need room. Free space or plan bigger
      disks; check snapshot usage in TrueNAS (Storage → Data1).
- [ ] Optional: smartctl-exporter on the NAS (`:9108`); its ScrapeConfig is
      written but commented out in `scrapeconfigs/kustomization.yaml`.
- [ ] Home Assistant: notify on `binary_sensor.home_ops_nas_problem`, like the
      backup problem automation.

### 4. Envoy external gateway resilience — done 2026-10-07, follow-ups

Root cause of the 2026-10-06 HA outage: Cilium L2 announcements ignore
`externalTrafficPolicy: Local` (documented limitation), so the node announcing
`10.30.50.200` can have no envoy pod and drops everything; home-ops-01 was 92%
CPU-requested, so Rook's osd-prepare job (system-node-critical) preempted the
envoy pod there. Fixed by `externalTrafficPolicy: Cluster` + PriorityClass
`homelab-critical` for the envoy pods, and Ceph CPU requests sized for the
cluster (~2 cores freed per storage node).

- [ ] `l2-announce-healthcheck` (kube-system) cannot see this failure: it
      probes the LoadBalancer IPs from a node with host networking, where
      Cilium delivers to the pods directly without the L2 path, so it stayed
      "up" during the outage. Either probe from outside the cluster (e.g.
      Home Assistant / Gatus on another host) or drop it now that the policy
      is Cluster.
- [ ] L2 lease is 120s/60s (Cilium default 15s/5s): failover after the
      announcing node dies takes up to ~3 min. Shorten if that matters.
- [ ] The GitHub Actions runner requests 1 core on home-ops-00; review.

### 5. SSO: native OIDC for apps with their own login

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

### 6. Authentik connection leak after a Postgres restart

- [ ] Authentik's embedded outpost leaks Postgres pools after a Postgres
      restart or switchover (details in [authentik-sso.md](authentik-sso.md),
      "Postgres connections"). Mitigated (max_connections 800, cap 500,
      alert, restart). Look for an upstream issue in goauthentik/authentik or
      open one; re-check after Authentik upgrades whether it still happens.

### 7. AI namespace follow-ups

- [ ] Move `browser-sessions` from `selfhosted` to `ai` (it is an agent
      tool). Its PVC holds the browser profiles (site sign-ins): restore it
      from VolSync in the new namespace, then point
      `ai/browser-sessions-mcp` at `browser-sessions.ai.svc`.
- [ ] LiteLLM has no database: only the master key works. For per-client
      keys and per-key MCP access, give it a Postgres database (CNPG role +
      DB, mind the connection budget, see docs/authentik-sso.md).

### 8. Smaller items

- [ ] Frigate: notification links never expire (`notification_proxy_expire_after_seconds: 0`
      in the HA Frigate integration options); set e.g. 86400.
- [ ] Paperless: nightly `document_exporter` to `/data/nas/export` (plain-file
      copy of all documents, picked up by the R2 sync of `Documents`).
- [ ] Test a VolSync restore of one app (procedure in
      [offsite-backup.md](offsite-backup.md)); Postgres has been drilled, volsync not.
- [ ] Cleanup: dead "Completed" pods left by node shutdowns, unused secret
      `network/envoy-oidc-hmac`.

## Done on 2026-10-07

- **Postgres**: a re-created `postgres16` restores from its archive instead
  of starting empty (#327, procedure in [offsite-backup.md](offsite-backup.md));
  backups moved to the Barman Cloud plugin (#328) and verified, restore drill
  identical to live; operator chart no longer held back (#329); deprecated
  `nodeMaintenanceWindow` / `enablePodMonitor` replaced by `enablePDB` and an
  own PodMonitor.
- **Ceph**: `osd.0` slow-op warning cleared (see item 3).

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
