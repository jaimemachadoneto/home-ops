# jaimenet.com — Homelab Context for Claude Code

This document gives Claude Code full context about the homelab network, infrastructure stack, and conventions so it can generate accurate configuration files without needing repeated explanation.

---

## Owner

Jaime Machado Leite — Barcelona, Spain.

---

## Network Overview

6 VLANs on a UniFi UCG-Fiber gateway. ISP is Digi Spain via PPPoE, ONT in bridge mode.

| VLAN | Name | Subnet | Gateway | Purpose |
|---|---|---|---|---|
| 10 | Main | 10.30.10.0/23 | 10.30.10.1 | Laptops, phones, desktops |
| 20 | IoT | 10.30.20.0/23 | 10.30.20.1 | Smart home devices, cameras, printers |
| 30 | Media | 10.30.30.0/23 | 10.30.30.1 | TVs, Alexas, streaming sticks |
| 40 | Guest | 10.30.40.0/23 | 10.30.40.1 | Isolated internet-only |
| 50 | Services | 10.30.50.0/23 | 10.30.50.1 | K8s nodes, NAS, HA, Plex |
| 98 | Management | 10.30.2.0/23 | 10.30.2.1 | UCG, switches, APs, Proxmox nodes |

### Key Static IPs

| IP | Role |
|---|---|
| 10.30.2.1 | UCG-Fiber |
| 10.30.3.2 | Proxmox node 1 |
| 10.30.3.3 | Proxmox node 2 |
| 10.30.3.4 | Proxmox node 3 |
| 10.30.3.5 | Proxmox node 4 |
| 10.30.20.5 | Home Assistant (IoT NIC) |
| 10.30.50.5 | Home Assistant (Services NIC — primary) |
| 10.30.50.6 | Plex VM |
| 10.30.50.10–20 | Kubernetes control plane nodes |
| 10.30.50.21–49 | Kubernetes worker nodes |
| 10.30.50.200 | Cilium Gateway LoadBalancer IP — single entry point for all services |
| 10.30.50.201–220 | Cilium LB IPAM pool |

---

## Infrastructure Stack

### Hypervisor

- **Proxmox VE** — 4-node cluster
- Nodes on **VLAN 98 (Management)**: `10.30.3.2` – `10.30.3.5`
- Host switch port is a trunk carrying VLANs 98, 50, 20
- Bridge: `vmbr0`, VLAN-aware, `bridge-vids 2-4094`

### Kubernetes

- Runs as VMs on Proxmox
- All nodes on **VLAN 50 (Services)** only — single NIC
- CNI: **Cilium** with Gateway API, LB IPAM, and L2 announcements enabled
- Service mesh: **Istio**
- Ingress: **Cilium Gateway API** (not Nginx Ingress)
  - `GatewayClass` name: `cilium`
  - Controller: `io.cilium/gateway-controller`
- Gateway IP: `10.30.50.200` (pinned via `cilium.io/lb-ipam-ips` annotation)
- Gateway namespace: `networking`
- Gateway name: `main-gateway`
- All services exposed via `HTTPRoute` referencing `main-gateway`

### TLS / Certificates

- **cert-manager** manages all certificates
- **ClusterIssuer**: `letsencrypt-prod` (and `letsencrypt-staging` for testing)
- Challenge: **DNS-01 via Cloudflare**
- Cloudflare API token secret: `cloudflare-api-token` in namespace `cert-manager`
- One wildcard certificate:
  - Resource: `jaimenet-wildcard` in namespace `networking`
  - Secret: `jaimenet-wildcard-tls` in namespace `networking`
  - Covers: `*.jaimenet.com` and `jaimenet.com`
- Gateway references this secret — no per-service certificates

### DNS

- **UniFi UCG-Fiber built-in DNS** — no Pi-hole
- Each VLAN uses its UCG gateway IP as DNS resolver
- Custom records in **UniFi → Settings → DNS → Local DNS Records**
- Every `*.jaimenet.com` subdomain → `10.30.50.200`
- No wildcard DNS support — each subdomain added individually
- Upstream: `1.1.1.1` / `9.9.9.9`

### Home Assistant

- Docker container (`ghcr.io/home-assistant/home-assistant:stable`)
- Linux VM on Proxmox, `--network host`
- Single VM NIC trunking VLANs 50 and 20 via subinterfaces:
  - `eth0.50` → `10.30.50.5/23`, gateway `10.30.50.1` (default route)
  - `eth0.20` → `10.30.20.5/23`, no gateway (on-link only)
- HA reaches IoT devices directly via `eth0.20` — no firewall rules needed
- Exposed via Gateway at `home.jaimenet.com`
- No NIC on Management (98), Main (10), or Media (30)

### Plex

- VM on Proxmox in Services VLAN: `10.30.50.6`, port `32400`
- Exposed via Gateway at `plex.jaimenet.com`
- Media VLAN devices connect via `https://plex.jaimenet.com` (manual server entry in Plex client)

---

## Conventions

### Kubernetes Namespaces

| Namespace | Purpose |
|---|---|
| `networking` | Gateway, GatewayClass, wildcard cert |
| `cert-manager` | cert-manager installation |
| `external-services` | Service + Endpoints + HTTPRoute for non-cluster hosts |
| `monitoring` | Prometheus, Grafana, Alertmanager, Uptime Kuma |
| `longhorn-system` | Longhorn storage |
| `argocd` | ArgoCD |

### Adding a New In-Cluster Service

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <service-name>
  namespace: <namespace>
spec:
  parentRefs:
    - name: main-gateway
      namespace: networking
      sectionName: https
  hostnames:
    - <service-name>.jaimenet.com
  rules:
    - backendRefs:
        - name: <k8s-service-name>
          port: <port>
```

Then add UniFi DNS record: `<service-name>.jaimenet.com → 10.30.50.200`

### Adding a Non-Cluster Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <name>
  namespace: external-services
spec:
  clusterIP: None
  ports:
    - name: http
      port: <port>
---
apiVersion: v1
kind: Endpoints
metadata:
  name: <name>
  namespace: external-services
subsets:
  - addresses:
      - ip: <static-ip>
    ports:
      - name: http
        port: <port>
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <name>
  namespace: external-services
spec:
  parentRefs:
    - name: main-gateway
      namespace: networking
      sectionName: https
  hostnames:
    - <name>.jaimenet.com
  rules:
    - backendRefs:
        - name: <name>
          port: <port>
```

Then add UniFi DNS record: `<name>.jaimenet.com → 10.30.50.200`

### File Layout

```
k8s/
├── networking/           # Gateway, GatewayClass, cert
├── cert-manager/         # Issuers, Cloudflare secret
├── cilium/               # LB pool, L2 announcement
├── external-services/    # Non-cluster service proxies
└── apps/
    ├── monitoring/
    ├── longhorn/
    └── argocd/
```

### Secrets

- Never commit secrets to Git
- Use sealed-secrets or external-secrets for anything in Git
- Cloudflare API token scoped to DNS Edit on `jaimenet.com` only

---

## Current Services

### External (non-cluster)

| Subdomain | Target IP | Port |
|---|---|---|
| home.jaimenet.com | 10.30.50.5 | 8123 |
| plex.jaimenet.com | 10.30.50.6 | 32400 |
| pve.jaimenet.com | 10.30.3.2 | 8006 |
| nas.jaimenet.com | 10.30.50.7 | 443 |

### In-Cluster

| Subdomain | Namespace |
|---|---|
| grafana.jaimenet.com | monitoring |
| prometheus.jaimenet.com | monitoring |
| longhorn.jaimenet.com | longhorn-system |
| uptime.jaimenet.com | monitoring |

---

## Firewall Summary

Default deny inter-VLAN. Explicit allows:

| Source | Destination | Ports | Reason |
|---|---|---|---|
| Main (10) | 10.30.50.200 | 443, 80 | All services via Gateway |
| Main (10) | Management (98) | 8006, 22 | Proxmox/UCG admin |
| Media (30) | 10.30.50.200 | 443 | Plex + Services via Gateway |
| Management (98) | Services (50) | 22 | VM management |
| Management (98) | Internet | any | Updates, VPN |
| Services (50) | Internet | any | Image pulls, cert issuance |
| IoT (20) | everywhere internal | — | Blocked |
| Media (30) | Management (98) | — | Blocked |
| Guest (40) | everywhere internal | — | Blocked |

HA → IoT is on-link via `eth0.20` — no firewall rule needed.

---

## Domain

`jaimenet.com` — DNS managed via **Cloudflare** (authoritative).

Internal: UCG-Fiber custom records override for `*.jaimenet.com` → `10.30.50.200`.
External: cert-manager uses Cloudflare API for DNS-01 challenge (`_acme-challenge.jaimenet.com` TXT record, created and removed automatically).

---

*Last updated: June 2026*
