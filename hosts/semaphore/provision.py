#!/usr/bin/env python3
"""Provision this repo's Ansible setup into a Semaphore instance.

Semaphore keeps its configuration (projects, repositories, inventories,
templates, schedules) in its own SQLite database rather than in git, so a
rebuilt instance starts empty. This script recreates that configuration from
scratch over the REST API.

It is idempotent: every object is looked up by name first and only created if
missing, so re-running it after adding a playbook is safe.

Designed to run ON the Semaphore host, so the SSH private key never leaves it:

    ssh root@semaphore.local.jaimenet.com 'python3 -' < provision.py

Configuration comes from the environment, with defaults suited to that host:

    SEMAPHORE_URL       default http://127.0.0.1:3000
    SEMAPHORE_TOKEN     API token (preferred). Mint a short-lived one on the host:
                          semaphore user token create --login admin \
                              --name provisioning --ttl 1h \
                              --config /opt/semaphore/config.json
    SEMAPHORE_USER      default admin        (only used for password login)
    SEMAPHORE_PASSWORD  password login, if no token is given
    SEMAPHORE_SSH_KEY   default /root/.ssh/semaphore_ansible
    GIT_URL             default https://github.com/jaimemachadoneto/home-ops.git
    GIT_BRANCH          default main

A token is preferable to the password: it is scoped, expiring, and revocable
without disturbing the interactive admin login.
"""

import json
import os
import sys
import urllib.error
import urllib.request
from http.cookiejar import CookieJar

URL = os.environ.get("SEMAPHORE_URL", "http://127.0.0.1:3000").rstrip("/")
TOKEN = os.environ.get("SEMAPHORE_TOKEN", "").strip()
USER = os.environ.get("SEMAPHORE_USER", "admin")
SSH_KEY_FILE = os.environ.get("SEMAPHORE_SSH_KEY", "/root/.ssh/semaphore_ansible")
GIT_URL = os.environ.get("GIT_URL", "https://github.com/jaimemachadoneto/home-ops.git")
GIT_BRANCH = os.environ.get("GIT_BRANCH", "main")

PROJECT_NAME = "home-ops"
KEY_NAME = "ssh-root"
REPO_NAME = "home-ops"
INVENTORY_NAME = "home-ops"
ENVIRONMENT_NAME = "default"

# Semaphore runs playbooks from the repository root, but this repo keeps its
# ansible.cfg under ansible/ - so the role search path has to be given
# explicitly or `roles: [z2m_watchdog]` will not resolve.
ENVIRONMENT_VARS = {
    "ANSIBLE_ROLES_PATH": "ansible/roles",
    "ANSIBLE_HOST_KEY_CHECKING": "False",
    "ANSIBLE_PIPELINING": "True",
}

TEMPLATES = [
    {
        "name": "ping",
        "playbook": "ansible/playbooks/ping.yml",
        "description": "Connectivity check across every managed host.",
    },
    {
        "name": "apt-update",
        "playbook": "ansible/playbooks/apt-update.yml",
        "description": "Update and upgrade apt packages. Debian/Ubuntu hosts only.",
    },
    {
        "name": "z2m-watchdog",
        "playbook": "ansible/playbooks/z2m-watchdog.yml",
        "description": "Deploy/refresh the Zigbee2MQTT watchdog on the z2m containers.",
    },
    {
        "name": "authorize-semaphore-key",
        "playbook": "ansible/playbooks/authorize-semaphore-key.yml",
        "description": "Authorize Semaphore's SSH key on managed hosts.",
    },
]

# Re-assert the watchdog config nightly so drift on the containers is corrected,
# and pick up package updates weekly. apt-update skips non-apt hosts itself.
SCHEDULES = [
    {"template": "z2m-watchdog", "cron": "0 4 * * *"},
    {"template": "apt-update", "cron": "0 5 * * 0"},
]

opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(CookieJar())
)


def authenticate():
    """Token if we have one, otherwise a password login that sets a cookie."""
    if TOKEN:
        return
    pw = os.environ.get("SEMAPHORE_PASSWORD")
    if not pw:
        sys.exit(
            "No credentials. Set SEMAPHORE_TOKEN (preferred) or SEMAPHORE_PASSWORD.\n"
            "Mint a token on the Semaphore host with:\n"
            "  semaphore user token create --login admin --name provisioning \\\n"
            "      --ttl 1h --config /opt/semaphore/config.json"
        )
    call("POST", "/api/auth/login", {"auth": USER, "password": pw})


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if TOKEN:
        headers["Authorization"] = "Bearer " + TOKEN
    req = urllib.request.Request(
        URL + path, data=data, method=method, headers=headers,
    )
    try:
        with opener.open(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:400]
        raise SystemExit(f"{method} {path} -> HTTP {exc.code}: {detail}")


def find(items, name):
    for item in items or []:
        if item.get("name") == name:
            return item
    return None


def ensure(label, listing, name, create):
    """Return an existing object by name, creating it only if absent."""
    existing = find(listing, name)
    if existing:
        print(f"  = {label:12} {name!r} (id {existing['id']})")
        return existing, False
    created = create()
    print(f"  + {label:12} {name!r} (id {created['id']}) created")
    return created, True


def main():
    print(f"Semaphore at {URL} ({'token' if TOKEN else 'password'} auth)")
    authenticate()

    project, _ = ensure(
        "project", call("GET", "/api/projects"), PROJECT_NAME,
        lambda: call("POST", "/api/projects", {
            "name": PROJECT_NAME,
            "alert": False,
            "max_parallel_tasks": 0,
        }),
    )
    pid = project["id"]
    base = f"/api/project/{pid}"

    with open(SSH_KEY_FILE) as fh:
        private_key = fh.read()

    keys = call("GET", base + "/keys")
    key, _ = ensure(
        "key", keys, KEY_NAME,
        lambda: call("POST", base + "/keys", {
            "name": KEY_NAME,
            "type": "ssh",
            "project_id": pid,
            "ssh": {"login": "root", "passphrase": "", "private_key": private_key},
        }),
    )
    # A public repo needs no credentials; Semaphore still wants a key reference.
    none_key = find(keys, "None") or find(keys, "none")
    git_key_id = none_key["id"] if none_key else key["id"]

    repo, _ = ensure(
        "repository", call("GET", base + "/repositories"), REPO_NAME,
        lambda: call("POST", base + "/repositories", {
            "name": REPO_NAME,
            "project_id": pid,
            "git_url": GIT_URL,
            "git_branch": GIT_BRANCH,
            "ssh_key_id": git_key_id,
        }),
    )

    env, _ = ensure(
        "environment", call("GET", base + "/environment"), ENVIRONMENT_NAME,
        lambda: call("POST", base + "/environment", {
            "name": ENVIRONMENT_NAME,
            "project_id": pid,
            "json": "{}",
            "env": json.dumps(ENVIRONMENT_VARS),
        }),
    )

    inv, _ = ensure(
        "inventory", call("GET", base + "/inventory"), INVENTORY_NAME,
        lambda: call("POST", base + "/inventory", {
            "name": INVENTORY_NAME,
            "project_id": pid,
            "type": "file",
            "inventory": "ansible/inventory/hosts.yml",
            "ssh_key_id": key["id"],
            "repository_id": repo["id"],
        }),
    )

    existing_templates = call("GET", base + "/templates")
    by_name = {}
    for spec in TEMPLATES:
        tpl, _ = ensure(
            "template", existing_templates, spec["name"],
            lambda s=spec: call("POST", base + "/templates", {
                "project_id": pid,
                "name": s["name"],
                "playbook": s["playbook"],
                "description": s["description"],
                "inventory_id": inv["id"],
                "repository_id": repo["id"],
                "environment_id": env["id"],
                "app": "ansible",
                "type": "",
                "arguments": "[]",
                "allow_override_args_in_task": False,
            }),
        )
        by_name[spec["name"]] = tpl

    for spec in SCHEDULES:
        tpl = by_name[spec["template"]]
        name = f"{spec['template']}-scheduled"
        # The project-wide /schedules listing always returns [], so an existence
        # check against it would recreate the schedule on every run. Schedules
        # are only readable per template.
        existing_schedules = call(
            "GET", f"{base}/templates/{tpl['id']}/schedules"
        ) or []
        ensure(
            "schedule", existing_schedules, name,
            lambda s=spec, t=tpl, n=name: call("POST", base + "/schedules", {
                "project_id": pid,
                "template_id": t["id"],
                "repository_id": repo["id"],
                "name": n,
                "cron_format": s["cron"],
                "active": True,
            }),
        )

    print("\nDone. Open the project and run the 'ping' template to verify.")


if __name__ == "__main__":
    main()
