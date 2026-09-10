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
> `install.sh`, `doco-cd/`, `scripts/` and `systemd/` in this directory belong
> to that superseded setup and are kept for reference - **they do not describe
> the running instance.**

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
- **No backups are configured on this instance.** The Pi had a nightly tar to
  the NAS (`scripts/backup.sh` + `systemd/semaphore-backup.timer`); that has
  not been reinstated here. Losing `access_key_encryption` from
  `/opt/semaphore/config.json` makes every stored SSH key and secret in the
  database unrecoverable, even with an intact copy of the database.

## Credentials

- Admin login: `admin`. The install-time password was written to
  `/root/semaphore.creds`; it is stale if the password has since been changed
  in the UI.
- `access_key_encryption` in `/opt/semaphore/config.json` encrypts the stored
  Ansible keys and secrets. Back it up somewhere other than this container.
- API tokens: `semaphore user token list --login admin`. Prefer short-lived
  tokens for automation over the admin password.
