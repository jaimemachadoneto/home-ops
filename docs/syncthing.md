# Syncthing

Syncthing in the namespace `selfhosted` keeps the notes vault (`~/Notes`)
the same on each device of the user. The cluster is always on, so the other
devices do not have to be online at the same time.

```
PC (~/Notes)  ⇄  syncthing (cluster)  ⇄  Android phone (Obsidian)
                        ⇅
                 Windows PC (optional)
```

| Item | Value |
| --- | --- |
| Web UI | `https://syncthing.${SECRET_DOMAIN}`. Authentik controls access (administrators only). |
| Sync address | `sync.${SECRET_DOMAIN}` (`10.30.50.209`), port 22000 TCP and UDP (LoadBalancer). external-dns makes the UniFi record. |
| Data | PVC `syncthing` (5Gi, `ceph-block`). VolSync copies it to the backup repository. |
| Folder path in the pod | `/var/syncthing/notes` |

## Before the first device

1. Make sure that Main (10.30.10.0/23) can reach `10.30.50.209` on port
   22000, TCP and UDP. On 2026-10-25, a PC on Main reached it with no new
   firewall rule. If a device at home connects through a relay, examine the
   UCG firewall rules (see `network.md`, section 11).
2. Open the web UI of the cluster. Go to **Actions > Settings**.
3. On the **Connections** tab, clear **Enable NAT traversal**. The router
   must not open port 22000 to the internet.
4. Remove the **Default Folder**. The cluster shares only the folder
   `notes`.

A restore from VolSync keeps these settings. Do them again only after a new
install with an empty volume.

## Connect a PC with nix-config

A Linux PC or a Mac with `features.syncthing = true` in `~/nix-config` gets
the cluster device, the folder `notes` and the ignore patterns from Nix.

1. Switch the PC to its configuration. Syncthing starts and makes the device
   ID of the PC.
2. At home, run `syncthing-join`. Give a name for the device, and confirm.

`syncthing-join` uses the REST API of the cluster at
`https://syncthing.${SECRET_DOMAIN}` (`syncthingGui` in `nix-secrets/domains.nix`).
It adds the device ID of the PC and shares the folder `notes` with it. You
can run it again: it does not add a device or a share two times.

The REST API is behind Authentik. The script signs in as the service account
`syncthing-join` with HTTP Basic auth, and it sends the Syncthing API key in
`X-API-Key`. The account can open only Syncthing
(`authentik/app/blueprints/forward-auth.yaml`). The route `syncthing` has
its own SecurityPolicy (`authentik/forward-auth/syncthing.yaml`), because
the outpost must also get the `Authorization` header.

The two secrets are in two places, with the same values:

| 1Password `Home-Ops/syncthing` (the cluster) | nix-secrets `secrets/secrets.yaml` (the script) | Use |
| --- | --- | --- |
| `api_key` | `keys/syncthing/api-key` | `STGUIAPIKEY` of Syncthing (ExternalSecret `syncthing`) |
| `join_token` | `keys/syncthing/join-token` | App password of `syncthing-join` (Authentik blueprint, through `authentik-secret`) |

nix-secrets is the source. To set the 1Password fields from it:

```sh
s=~/nix-secrets/secrets/secrets.yaml
op item create --vault Home-Ops --category "Secure Note" --title syncthing \
  "api_key[password]=$(sops -d --extract '["keys"]["syncthing"]["api-key"]' $s)" \
  "join_token[password]=$(sops -d --extract '["keys"]["syncthing"]["join-token"]' $s)"
```

A person with these secrets can share the vault with any device. To revoke
them, put new values in nix-secrets, then copy them to 1Password
(`op item edit` with the same fields). External Secrets updates the
cluster, and Reloader restarts Syncthing and Authentik.

## Connect another device

1. Install Syncthing on the device:
   - Linux PC or Mac: see [Connect a PC with nix-config](#connect-a-pc-with-nix-config).
   - Android: Syncthing-Fork.
   - Windows: Syncthing Windows Setup, or the SyncTrayzor fork of
     GermanCoding.
2. Open the web UI of the cluster. Click **Actions > Show ID**. Copy the
   device ID.
3. On the device, add a remote device with that ID. Set its addresses to
   `tcp://sync.${SECRET_DOMAIN}:22000, quic://sync.${SECRET_DOMAIN}:22000, dynamic`.
   Use the real domain in place of `${SECRET_DOMAIN}`.
4. The web UI of the cluster shows a prompt for the new device. Compare the
   device ID in the prompt with the ID on the device (**Actions > Show
   ID**). Accept the device only if the two IDs are the same.
5. Share the folder `notes` with the device. Select its path on the device:
   - Linux PC: `~/Notes`.
   - Android: a folder that Obsidian opens as a vault.
   - Windows: a folder such as `C:\Users\<user>\Notes`.

Do not set the cluster as an introducer, and do not turn on automatic
acceptance of folders. A device that you did not compare must not get the
vault.

Away from home, the name `sync.${SECRET_DOMAIN}` does not resolve, and a
device cannot reach `10.30.50.209`. It then connects through a public
Syncthing relay. The relay cannot read the data, because
Syncthing encrypts each connection from end to end.

## Ignore patterns

Add these lines to the ignore patterns of the folder on each device. These
files are different on each device. Each device has its own Obsidian layout
and its own git data:

```
.git
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.trash
```

## Web UI password

Syncthing shows a warning that the web UI has no password. Two controls
replace the password:

- Authentik controls access to the route on `envoy-internal`.
- The CiliumNetworkPolicy `syncthing` lets only `envoy-internal` and the
  kubelet probes reach port 8384. Other pods cannot skip Authentik.

You can ignore the warning.
