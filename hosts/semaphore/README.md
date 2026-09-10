# Semaphore

Ansible Semaphore, the UI/scheduler that runs the playbooks in `ansible/`.

Runs as a **Docker container inside an unprivileged Proxmox LXC**
(`semaphore`, `semaphore.local.jaimenet.com`, `10.30.51.104`, Ubuntu 24.04).

| | |
|---|---|
| stack | `/opt/semaphore/docker-compose.yml` (copy of the one here) |
| control | `cd /opt/semaphore && docker compose ps \| logs \| up -d` |
| database | `/opt/semaphore/data/database.db` (SQLite, WAL) |
| config | `/opt/semaphore/config/config.json` |
| secrets | `/opt/semaphore/semaphore.env` |
| version | pinned by tag+digest in `docker-compose.yml` so Renovate can bump it |

Reachable at `https://semaphore.${SECRET_DOMAIN}` via the cluster's
`envoy-internal` gateway (`kubernetes/apps/external-ingresses/semaphore/`).
That `Backend` targets the **FQDN** `semaphore.local.jaimenet.com:3000` rather
than an IP, so moving Semaphore only needs a DNS change - the cluster follows
automatically. That is how it survived the move off the Pi.

> **History.** This ran on a Raspberry Pi 3B (`10.30.50.210`) until the Pi
> died, was rebuilt as a native systemd install in this LXC, and was then moved
> back onto Docker to regain the pinned-image/GitOps workflow. The native
> install's leftover files are parked in
> `/opt/semaphore/native-install-superseded/` on the host and can be deleted
> once you are happy.

## Configuring it (provision.py)

Semaphore keeps projects, repositories, inventories, templates and schedules in
its own database, not in git - so a rebuilt instance comes up empty.
`provision.py` recreates that configuration over the REST API. It is
idempotent: objects are looked up by name and only created when missing, so
re-run it after adding a playbook.

It needs an API token. Mint a short-lived one - this avoids having to know or
change the interactive admin password:

```sh
ssh root@semaphore.local.jaimenet.com
docker exec semaphore semaphore user token create --login admin \
    --name provisioning --ttl 1h --config /etc/semaphore/config.json
```

Then, from a checkout of this repo:

```sh
ssh root@semaphore.local.jaimenet.com "SEMAPHORE_TOKEN='<token>' python3 -" \
    < hosts/semaphore/provision.py
```

Running it *on* the host means the SSH private key never leaves that machine.

What it creates: a `home-ops` project, an `ssh-root` key, the git repository, a
`home-ops` inventory pointing at `ansible/inventory/hosts.yml`, a `default`
environment, one template per playbook, and a nightly `z2m-watchdog` schedule.

### The environment matters

The `default` environment sets `ANSIBLE_ROLES_PATH=ansible/roles`. Semaphore
runs playbooks from the **repository root**, but this repo's `ansible.cfg`
(which carries `roles_path`) lives under `ansible/` and is therefore never
loaded. Without that variable, `roles: [z2m_watchdog]` does not resolve and the
z2m-watchdog template fails with "the role was not found".

## SSH identity

Semaphore authenticates to managed hosts with its own keypair at
`/root/.ssh/semaphore_ansible` on the LXC, rather than borrowing a personal
key. The private half is stored (encrypted) in Semaphore's database as the
`ssh-root` key; the public half is authorized on managed hosts by:

```sh
ansible-playbook playbooks/authorize-semaphore-key.yml
```

Run that from a machine that already has root access to the targets. For a host
that trusts no key you hold, install it with a password instead - the
`.gitignore` excludes `*.pub`, so take the key off the Semaphore host:

```sh
ssh root@semaphore.local.jaimenet.com cat /root/.ssh/semaphore_ansible.pub > /tmp/sem.pub
ssh-copy-id -i /tmp/sem.pub root@<host>
```

## Backups

`scripts/backup.sh` runs nightly via `systemd/semaphore-backup.timer` **on the
LXC, not in the container**, and archives everything Semaphore cannot be
rebuilt without:

- `data/database.db` - projects, templates, schedules, encrypted keys
- `config/config.json` - including `access_key_encryption`, which decrypts them
- `semaphore.env` - the same key plus the admin password, as compose reads it

The database and its encryption key are worthless apart, so they always travel
together - and that makes the archive sensitive, so it is written `0600`.

The database is snapshotted with SQLite's backup API rather than copied.
Semaphore keeps it open in **WAL mode**, so a plain `cp` or `tar` of a live
database can capture a torn set of pages and silently drop transactions still
sitting in the `-wal`. Each snapshot is checked with `PRAGMA integrity_check`
so a bad archive fails the backup loudly rather than during a restore. The
script also refuses to run if the expected files are missing, so a layout
change cannot leave it quietly archiving something stale.

Retention is 14 days locally in `/opt/semaphore/backups` and 30 days on the
NAS. Archives are ~32 KB.

### Offsite copies are Proxmox's job

The nightly archives stay on the container; getting them off it is handled by
**`vzdump` of the whole LXC** on the PVE host, not by this container pushing to
a share.

That split is deliberate rather than a fallback. A `vzdump` of a running
container copies the SQLite database mid-write; WAL usually makes that
recoverable, but "usually" is thin cover for the store holding credentials to
every host in the fleet. The nightly logical snapshot is already consistent and
integrity-checked, so `vzdump` sweeps up known-good archives regardless of what
it catches the live database doing. Two layers, and the cheap one does the hard
part.

The container is deliberately **unprivileged**, which means it cannot mount NFS
at all - the kernel refuses it from inside a user namespace no matter what the
export allows (`tmpfs` mounts fine, `nfs` returns `Operation not permitted`).
Making it privileged does work, and was tried, but it costs the AppArmor
protection too (see gotchas) and that is a poor trade for a host with SSH
access to everything.

If you ever do want a share visible in here, attach it from the PVE host rather
than mounting it inside:

```sh
pct set <ctid> -mp0 /mnt/pve/semaphore,mp=/mnt/semaphore-backup
```

`backup.sh` already copies to `/mnt/semaphore-backup` whenever something is
mounted there, so a bind mount starts working with no changes.

### Restore

```sh
cd /opt/semaphore && docker compose down
tar -xzf /opt/semaphore/backups/semaphore-<timestamp>.tar.gz -C /tmp/restore
cp /tmp/restore/database.db  /opt/semaphore/data/
cp /tmp/restore/config.json  /opt/semaphore/config/
cp /tmp/restore/semaphore.env /opt/semaphore/
chown -R 1001:1001 /opt/semaphore/data /opt/semaphore/config
docker compose up -d
```

Delete any `-wal`/`-shm` beside the restored database: the snapshot is
self-contained and stale sidecars only confuse SQLite. Then verify rather than
trust - check the templates came back:

```sh
docker exec semaphore sh -c 'ls /var/lib/semaphore'
curl -s -H "Authorization: Bearer <token>" localhost:3000/api/project/2/templates
```

## Known gotchas

- **Playbooks run from the git remote, not your working tree.** Semaphore
  clones the repository at the configured branch, so unpushed work is not
  there. A template failing with "playbook could not be found" almost always
  means the change has not been pushed.
- **DNS gets reset on container restart.** Proxmox rewrites `/etc/resolv.conf`
  from the CT config each time the container starts. This container shipped
  pointing at `1.1.1.1` with an unrelated search domain, which cannot resolve
  any internal `*.jaimenet.com` name, so every playbook failed to connect. The
  durable fix is on the PVE host:

  ```sh
  pct set <ctid> --nameserver 10.30.50.1 --searchdomain jaimenet.com
  ```

- **`ansible/requirements.yml` is not auto-installed.** Semaphore looks for
  `requirements.yml` only at the repository root and under `collections/`,
  `roles/`, and the playbook's own directory - not under `ansible/`.
  Collections come from the image. Move or copy the file to
  `collections/requirements.yml` if you need a version the image lacks.
- **`semaphore.env` must not live inside a directory owned by uid 1001** - the
  host-side `docker compose` reads it, and secrets silently come up empty if it
  cannot.
- **A privileged LXC cannot load AppArmor profiles.** Only relevant if you make
  this container privileged again: Docker tries to apply its `docker-default`
  profile, `apparmor_parser` returns "Access denied. You need policy admin
  privileges", and Docker then refuses to start *any* container - while logging
  it and carrying on to "Loading containers: done", so the daemon looks healthy
  and `systemctl is-active docker` says `active` while nothing runs. The
  workaround is `security_opt: [apparmor=unconfined]` in the compose file,
  which is why unprivileged is preferable: it keeps the profile.
- **systemd will not run automount units inside a container.** It reports
  "unit type of ... .automount not supported on this system", so an
  `x-systemd.automount` fstab entry silently does nothing - `autofs` being
  present in `/proc/filesystems` is a red herring. The NFS share therefore uses
  a plain `_netdev,nofail` entry when one exists at all, and `backup.sh` mounts
  it explicitly rather than trusting an automount. Without that a configured
  share is silently never mounted and every copy quietly stays local.
- **Changing `SEMAPHORE_ACCESS_KEY_ENCRYPTION` orphans every stored key.** The
  database stays intact but its SSH keys and secrets become undecryptable. It
  was carried across the native → Docker migration for exactly this reason.

## Not yet done

`doco-cd` is **not** set up on this host, so the container does not
auto-deploy: Renovate can open image-bump PRs, but applying one currently means
`docker compose pull && docker compose up -d` by hand. `install.sh` and
`doco-cd/` describe the Pi's arrangement and would need adapting.

## Credentials

- Admin login: `admin`, password in `/opt/semaphore/semaphore.env` (`0600`).
- `SEMAPHORE_ACCESS_KEY_ENCRYPTION` in the same file decrypts the stored
  Ansible keys. Back it up somewhere other than this container.
- API tokens: `docker exec semaphore semaphore user token list --login admin`.
  Prefer short-lived tokens for automation over the admin password.
