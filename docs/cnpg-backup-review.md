# Postgres backup review (handoff for a local Claude Code session)

This is a briefing for a Claude Code session running on a machine with
`kubectl` access to the cluster. It continues a review that was done without
cluster access, so everything below about the live state is still unverified.

Related PR: https://github.com/jaimemachadoneto/home-ops/pull/308
(branch `claude/optimistic-hamilton-r3z7v6`)

## How to start the session

```bash
cd ~/path/to/home-ops
git fetch origin && git checkout claude/optimistic-hamilton-r3z7v6
kubectl config current-context        # confirm it is the home-ops cluster
claude
```

Then give it this prompt:

> Read `docs/cnpg-backup-review.md` and work through it with me. Start with
> the read-only checks in "Step 1" and report what you find before changing
> anything.

## Rules for the session

The owner has lost data before, so treat the database as precious.

- **Read-only first.** Run only `get`, `describe`, `logs`, and `exec` commands
  that only read (`psql` `SELECT`, `mc ls`), until the owner agrees to a change.
- **Ask before any command that changes things**: `kubectl apply/patch/delete/edit`,
  `flux reconcile/suspend/resume`, `mc rm/cp/mirror`, or anything that writes
  to the S3 bucket.
- **Never** delete or patch the `postgres16` `Cluster`, its PVCs
  (`postgres16-1`, `postgres16-2`, ...) or its `Backup` objects. **Never** change
  `serverName` in `cluster16.yaml` without an agreed plan (see Step 4).
- **Never** print secret values (S3 keys, Postgres passwords) in output. Use
  them through environment variables or `kubectl exec`.
- Changes are made via GitOps: edit files, commit to the branch, push, and let
  Flux apply them. Don't `kubectl apply` manifests by hand.

## Background

### Setup (`kubernetes/apps/database/cloudnative-pg/`)

- One CNPG cluster, `postgres16`, in namespace `database`, with 2 instances.
  It runs on `openebs-hostpath`, which is each node's local `sdc` disk. It is
  **not** covered by volsync (see `docs/storage.md`).
- Every app that uses Postgres shares this cluster: Authentik, Paperless,
  and others.
- Backups use CNPG's built-in Barman (`barmanObjectStore`) and go to MinIO on
  the NAS: `s3://cloudnative/postgres16-v0/` at `http://nas.jaimenet.com:9000`.
  WAL is shipped continuously, a base backup is taken `@daily`, and backups
  are kept for `31d`. The S3 credentials come from the 1Password item `s3`,
  through `cloudnative-pg-secret`.

### Risks found in the review, worst first

1. **A rebuilt cluster starts empty.** `bootstrap: initdb` means that if the
   `Cluster` is ever created again (namespace or Flux prune, cluster rebuild,
   both local disks lost), CNPG creates a fresh empty database. It does not
   restore. The new cluster then tries to archive to the same
   `postgres16-v0` path, Barman refuses to write over an existing archive,
   and WAL archiving fails, so new data isn't backed up either. This is the
   most likely cause of earlier data loss.
2. **Nothing alerted when backups stopped.** The PR adds alerts for this.
3. **The restore has never been tested.** The PR adds a restore drill.
4. **The backup method is deprecated.** In-tree `barmanObjectStore` has been
   deprecated since CNPG 1.26 in favour of the Barman Cloud Plugin. The
   operator chart follows `semver: 0.x` and is auto-updated by Renovate, so
   an upgrade could stop backups.
5. Smaller points: a single backup target (the same NAS as volsync), and an
   old image (`16.4-29`).

### What PR #308 adds

- `cluster/prometheusrule.yaml` gets four critical alerts, routed to Pushover:
  `CNPGNoRecentBackup` (more than 26h), `CNPGBackupMetricsMissing`,
  `CNPGLastBackupFailed` and `CNPGWalArchivingStalled` (more than 1h). The
  metric names come from CNPG's default monitoring queries and should be
  confirmed in Prometheus.
- `restore-test/` plus a `cloudnative-pg-restore-test` Flux Kustomization in
  `ks.yaml`. `postgres16-restore-test` is a single-instance cluster
  bootstrapped by recovery from `postgres16-v0`. It has **no `backup:`
  section**, so it never writes to the bucket. `postgres16-restore-verify` is
  a Job that prints the databases, exact row counts of the largest tables,
  and an Authentik summary.

## Step 1: Read-only health check (before merging)

```bash
# Cluster health, and when the last backup / earliest recovery point are
kubectl -n database get cluster postgres16
kubectl -n database get cluster postgres16 -o jsonpath='{.status.lastSuccessfulBackup}{"\n"}{.status.firstRecoverabilityPoint}{"\n"}'
kubectl -n database get cluster postgres16 -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}'

# Backups: expect one completed per day
kubectl -n database get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp | tail -15
kubectl -n database get scheduledbackup postgres -o yaml | grep -A5 status

# Which pod is primary, then the archiver stats on it
kubectl -n database get pods -l cnpg.io/cluster=postgres16 -L cnpg.io/instanceRole
kubectl -n database exec <primary-pod> -c postgres -- psql -c \
  "select last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time from pg_stat_archiver;"

# Archive errors in the logs
kubectl -n database logs <primary-pod> -c postgres --since=24h | grep -iE 'archive|barman|wal-archive' | tail -30

# Databases and sizes
kubectl -n database exec <primary-pod> -c postgres -- psql -c \
  "select datname, pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate order by 1;"

# Operator version (relevant to risk 4)
kubectl -n database get deploy -l app.kubernetes.io/name=cloudnative-pg -o jsonpath='{..image}{"\n"}'
```

Optionally, list the bucket. This needs the MinIO client (`mc`) and the
credentials from the 1Password item `s3`:

```bash
mc alias set nas http://nas.jaimenet.com:9000 "$S3_KEY" "$S3_SECRET"
mc ls nas/cloudnative/                         # which serverNames exist (v0 only?)
mc ls nas/cloudnative/postgres16-v0/base/      # one folder per base backup
mc ls nas/cloudnative/postgres16-v0/wals/ | tail
```

**What healthy looks like:** `ContinuousArchiving=True`,
`lastSuccessfulBackup` within the last 24h, a daily run of `completed`
backups, `last_archived_time` within the last few minutes, and
`failed_count` 0 (or `last_failed_time` older than `last_archived_time`).

**If it is unhealthy, stop and report before going further.** Common causes:

- "Expected empty archive": risk 1 has already happened. The cluster was
  re-created on top of the old archive.
- S3 auth or connection errors: the credentials or the NAS/MinIO.
- No `Backup` objects at all: a problem with the ScheduledBackup.

## Step 2: Merge PR #308, then run the restore drill

When the owner merges the PR, Flux creates the alerts and the restore cluster.
Then:

```bash
flux get kustomizations -n database | grep cloudnative
kubectl -n database get cluster postgres16-restore-test -w        # wait for "Cluster in healthy state"
kubectl -n database get pods -l cnpg.io/cluster=postgres16-restore-test
kubectl -n database logs job/postgres16-restore-verify

# The point in time the restore reached
kubectl -n database logs -l cnpg.io/cluster=postgres16-restore-test,cnpg.io/jobRole=full-recovery --tail=-1 \
  | grep -iE 'last completed transaction|recovery stopping|consistent recovery'
```

Confirm the alerts were loaded and have data:

```bash
kubectl -n database get prometheusrule cloudnative-pg-rules -o yaml | grep 'alert: CNPG'
# In Prometheus/Grafana, these should all return values:
#   cnpg_collector_last_available_backup_timestamp{namespace="database"}
#   cnpg_collector_last_failed_backup_timestamp{namespace="database"}
#   cnpg_pg_stat_archiver_seconds_since_last_archival{namespace="database"}
```

If a metric name is missing, fix the rule on the branch rather than leaving
an alert that can never fire. `CNPGBackupMetricsMissing` will fire if the
backup timestamp metric doesn't exist.

**How to read the result:**

- The restore never finishes: **the backups are not usable.** This is the top
  priority. Look at the recovery pod logs.
- The restore finishes, but the last transaction is old: WAL archiving
  stopped at that time. Compare it with Step 1.
- The restore finishes and is recent, the row counts look right, and the
  Authentik `last_login` is recent: the backups are good.

**Clean up** by removing the `cloudnative-pg-restore-test` entry from `ks.yaml`.
Commit and push, and Flux prunes the test cluster and its PVC. Check that it's
gone with `kubectl -n database get cluster,pvc`.

## Step 3: Follow-up work (needs a plan agreed with the owner)

1. **Restore by default on rebuild (risk 1).** Change `cluster16.yaml` so a
   re-created cluster restores instead of starting empty: `bootstrap.recovery`
   from the current serverName, write to a bumped serverName (`v0` to `v1`),
   and document the procedure in this file or `docs/storage.md`. Agree the
   procedure first. Changing `serverName` on the running cluster starts a new
   archive path and needs an immediate base backup there.
2. **Move to the Barman Cloud Plugin (risk 4)** before an operator upgrade
   removes in-tree Barman support. Check the operator version found in Step 1
   against the CNPG release notes. Consider pinning the operator chart until
   the move is done.
3. Optionally, add an off-site copy of the `cloudnative` bucket, such as
   replication from MinIO to cloud storage.

## Step 4: Afterwards, Authentik via GitOps

This was the original goal. It was paused to make sure the database holding
Authentik's config is safe first. The agreed direction:

- Manage Authentik configuration with **blueprints** loaded from a ConfigMap
  (`blueprints.configMaps` in the HelmRelease), so providers and applications
  live in git.
- Protect apps without built-in login using **per-HTTPRoute Envoy Gateway
  `SecurityPolicy` extAuth**, pointing at the embedded outpost
  (`authentik-server.selfhosted:80`, path `/outpost.goauthentik.io/auth/envoy`).
  Add a `ReferenceGrant` in `selfhosted` and a reusable component under
  `kubernetes/components/`.
- Use native OIDC for apps that support it (Open WebUI, Grafana, Paperless,
  ...).
- Done (2026-10): forward auth via `components/authentik-forward-auth`, see
  `docs/authentik-sso.md`; the old gateway-wide OIDC attempt and the nginx
  CORS proxy in front of Authentik were removed.
- Open questions for the owner: which apps go first, and which apps that
  were set up by hand in the Authentik UI need to be recreated as blueprints.
  Before changing anything in Authentik, list what exists today:

  ```bash
  kubectl -n selfhosted exec deploy/authentik-server -- ak shell -c \
    "from authentik.core.models import Application; print([(a.slug, a.provider) for a in Application.objects.all()])"
  ```
