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

## Connect a device

1. Install Syncthing on the device:
   - Linux PC: `services.syncthing` in `~/nix-config`.
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
