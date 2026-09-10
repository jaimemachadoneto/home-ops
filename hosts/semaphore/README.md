# Semaphore

Ansible Semaphore, the UI/scheduler that runs the playbooks in `ansible/`.

Currently an **Ubuntu 24.04 LXC container on Proxmox** (`semaphore`,
`semaphore.local.jaimenet.com`, `10.30.51.104`), with Semaphore installed
**natively** - no Docker - from the Proxmox community-scripts helper. It runs
as a plain systemd unit:

| | |
|---|---|
| service | `systemctl status semaphore` |
| binary | `/usr/bin/semaphore server --config /opt/semaphore/config.json` |
| config | `/opt/semaphore/config.json` |
| database | `/opt/semaphore/database.sqlite` (SQLite) |
| version | 2.19.12 |

Reachable at `https://semaphore.${SECRET_DOMAIN}` via the cluster's
`envoy-internal` gateway (`kubernetes/apps/external-ingresses/semaphore/`).
That `Backend` targets the **FQDN** `semaphore.local.jaimenet.com:3000` rather
than an IP, so moving Semaphore to a new host only needs a DNS change - the
cluster follows automatically. That is how it survived the move off the Pi.

> **This replaced a Raspberry Pi 3B** (`10.30.50.210`) that ran Semaphore as a
> Docker container deployed by doco-cd. The Pi died. `docker-compose.yml`,
> `install.sh`, `semaphore.env.example` and `doco-cd/` in this directory belong
> to that superseded setup and are kept for reference - **they do not describe
> the running instance.** `scripts/` and `systemd/` have been brought forward
> and do apply.

## Configuring it (provision.py)

Semaphore keeps projects, repositories, inventories, templates and schedules in
its own SQLite database, not in git - so a rebuilt instance comes up empty.
`provision.py` recreates that configuration over the REST API. It is
idempotent: objects are looked up by name and only created when missing, so
re-run it after adding a playbook.

It needs an API token. Mint a short-lived one on the host - this avoids having
to know or change the interactive admin password:

```sh
ssh root@semaphore.local.jaimenet.com
semaphore user token create --login admin --name provisioning --ttl 1h \
    --config /opt/semaphore/config.json
```

Then, from a checkout of this repo:

```sh
ssh root@semaphore.local.jaimenet.com "SEMAPHORE_TOKEN='<token>' python3 -" \
    < hosts/semaphore/provision.py
```

Running it *on* the host means the SSH private key never leaves that machine.
See the docstring for the full set of environment variables.

What it creates: a `home-ops` project, an `ssh-root` key, the git repository,
a `home-ops` inventory pointing at `ansible/inventory/hosts.yml`, a `default`
environment, one template per playbook, and a nightly `z2m-watchdog` schedule.

### The environment matters

The `default` environment sets `ANSIBLE_ROLES_PATH=ansible/roles`. Semaphore
runs playbooks from the **repository root**, but this repo's `ansible.cfg`
(which carries `roles_path`) lives under `ansible/` and is therefore never
loaded. Without that variable, `roles: [z2m_watchdog]` does not resolve and
the z2m-watchdog template fails with "the role was not found".

## SSH identity

Semaphore authenticates to managed hosts with its own keypair at
`/root/.ssh/semaphore_ansible` on the Semaphore host, rather than borrowing a
personal key. The private half is stored (encrypted) in Semaphore's database as
the `ssh-root` key; the public half is authorized on managed hosts by:

```sh
ansible-playbook playbooks/authorize-semaphore-key.yml
```

Run that from a machine that already has root access to the targets. Hosts that
are down, or that do not yet trust the key you are running as, are skipped -
check the play recap and fix those by hand.

For a host that does not yet trust any key you hold, install the key with a
password instead. The repo's `.gitignore` excludes `*.pub`, so fetch the key
from the Semaphore host rather than looking for it here (the same value is
inlined in the playbook above):

```sh
ssh root@semaphore.local.jaimenet.com cat /root/.ssh/semaphore_ansible.pub > /tmp/sem.pub
ssh-copy-id -i /tmp/sem.pub root@<host>
```

After that the playbook above manages the host normally.

## Known gotchas

- **Playbooks run from the git remote, not your working tree.** Semaphore
  clones the repository at the configured branch, so uncommitted or unpushed
  work simply is not there. A template failing with "playbook could not be
  found" almost always means the change has not been pushed.
- **DNS gets reset on container restart.** Proxmox rewrites
  `/etc/resolv.conf` from the CT config each time the container starts. This
  container shipped pointing at `1.1.1.1` with an unrelated search domain,
  which cannot resolve any internal `*.jaimenet.com` name, so every playbook
  failed to connect. The durable fix is on the PVE host:

  ```sh
  pct set <ctid> --nameserver 10.30.50.1 --searchdomain jaimenet.com
  ```

- **`ansible/requirements.yml` is not auto-installed.** Semaphore looks for
  `requirements.yml` only at the repository root and under
  `collections/`, `roles/`, and the playbook's own directory - not under
  `ansible/`. Collections currently come from the distro `ansible` package
  (community.general 8.3.0, ansible.posix 1.5.4), which satisfies these
  playbooks. Move or copy the file to `collections/requirements.yml` if you
  ever need a version the distro package does not provide.
- **The NAS export does not exist yet**, so backups are currently local-only -
  see Backups below.

## Backups

`scripts/backup.sh` runs nightly via `systemd/semaphore-backup.timer` and
archives the only two files Semaphore cannot be rebuilt without:

- `database.sqlite` - projects, templates, schedules, and the encrypted keys
- `config.json` - including `access_key_encryption`, which decrypts them

They are useless apart: an intact database with a lost encryption key means
every stored SSH key and secret is unrecoverable. The archive therefore holds
both, and is written `0600` because it effectively contains those secrets.

The database is snapshotted with SQLite's backup API rather than copied.
Semaphore keeps it open in **WAL mode**, so a plain `cp` or `tar` of a live
database can capture a torn set of pages and silently drop transactions still
sitting in the `-wal`. Each snapshot is checked with `PRAGMA integrity_check`
so a bad archive fails the backup loudly instead of surfacing during a restore.

Retention is 14 days locally in `/opt/semaphore/backups` and 30 days on the
NAS. The archives are ~26 KB, so this costs nothing.

### The NAS export

The share is `nas.jaimenet.com:/mnt/Data1/Semaphore` - **capital S**, and NFS
paths are case-sensitive, so the fstab entry has to match exactly. It needs a
read-write ACL for this container's address, `10.30.51.104`, granted on the NAS
admin UI. The container is on a /23, so `10.30.50.x` and `10.30.51.x` are the
same subnet; confirm the address with `ip route get 10.30.50.7`, which shows
the source address the NAS actually sees.

Two failure modes, easy to tell apart:

- `mount.nfs4: Operation not permitted` - the export exists but this address is
  not in its ACL.
- `warning: /mnt/semaphore-backup not mounted, backup kept locally only` - the
  script degraded gracefully; the local copy still happened.

Local-only backups do not protect against losing this container, so treat the
warning as something to fix rather than as steady state. The fstab entry and
automount are already in place, so backups reach the NAS on the next run once
the ACL is right, with no further changes here.

### Restore

```sh
systemctl stop semaphore
tar -xzf /opt/semaphore/backups/semaphore-<timestamp>.tar.gz -C /opt/semaphore
systemctl start semaphore
```

The archive expands to `database.sqlite` and `config.json` exactly where they
belong. Any `-wal`/`-shm` files left beside the old database can be deleted:
the snapshot is self-contained and stale sidecars only confuse SQLite.

Verify a restore rather than trusting it - check that the template list comes
back:

```sh
python3 -c "import sqlite3;print([r[0] for r in sqlite3.connect('/opt/semaphore/database.sqlite').execute('select name from project__template')])"
```

## Credentials

- Admin login: `admin`. The install-time password was written to
  `/root/semaphore.creds`; it is stale if the password has since been changed
  in the UI.
- `access_key_encryption` in `/opt/semaphore/config.json` encrypts the stored
  Ansible keys and secrets. Back it up somewhere other than this container.
- API tokens: `semaphore user token list --login admin`. Prefer short-lived
  tokens for automation over the admin password.
