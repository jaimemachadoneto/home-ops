# jaimenet.com — Home Network Configuration Project

> **Stack:** UniFi (UCG-Fiber) · 6 VLANs · Kubernetes · Cilium Gateway API · cert-manager · Let's Encrypt DNS-01 (Cloudflare) · Home Assistant (dual-homed: Services + IoT)

> **Status: target-state design — not yet implemented.** This document describes a planned redesign of the home network and is **not** the cluster's current configuration. Today the cluster runs on a flat `10.30.0.0/16` network (e.g. nodes like `10.30.4.1`, gateway `10.30.0.1`, kube-api VIP `10.30.6.50`, Cilium LB pool `10.30.6.30-199`), IoT devices are on VLAN 303 (`10.1.3.0/24` via multus, see `kubernetes/apps/network/multus/networks/iot.yaml`), a VPN macvlan already exists (`kubernetes/apps/network/multus/networks/vpn.yaml`, gateway `10.30.212.1`), and ingress is handled by ingress-nginx (`kubernetes/apps/network/ingress-nginx/`) rather than Cilium Gateway API. Use this document as the reference target when planning the migration.

---

## Table of Contents

1. [Network Architecture Overview](#1-network-architecture-overview)
2. [VLAN Design](#2-vlan-design)
3. [UniFi Configuration](#3-unifi-configuration)
4. [Internal DNS (UniFi Custom Records)](#4-internal-dns-unifi-custom-records)
5. [Home Assistant — Dual-VLAN Setup](#5-home-assistant--dual-vlan-setup)
6. [Plex — Media VLAN Access](#6-plex--media-vlan-access)
7. [Kubernetes: Cilium Gateway API](#7-kubernetes-cilium-gateway-api)
8. [TLS: cert-manager + Let's Encrypt DNS-01](#8-tls-cert-manager--lets-encrypt-dns-01)
9. [Ingress Routing Strategy](#9-ingress-routing-strategy)
10. [Non-Cluster Services (External via Gateway)](#10-non-cluster-services-external-via-gateway)
11. [Firewall Rules](#11-firewall-rules)
12. [Security Hardening](#12-security-hardening)
13. [Operational Runbook](#13-operational-runbook)

---

## 1. Network Architecture Overview

```
Internet
    │
    ▼
UCG-Fiber (PPPoE — Digi Spain)
    │
    ├── VLAN 10  — Main        10.30.10.0/23   (Laptops, phones, desktops)
    ├── VLAN 20  — IoT         10.30.20.0/23   (Smart home devices, cameras, printers)
    ├── VLAN 30  — Media       10.30.30.0/23   (TVs, Alexas, streaming sticks)
    ├── VLAN 40  — Guest       10.30.40.0/23   (Isolated internet-only)
    ├── VLAN 50  — Services    10.30.50.0/23   (K8s nodes, NAS, HA VM, Plex VM)
    └── VLAN 98  — Management  10.30.2.0/23   (UCG, switches, APs, Proxmox nodes)

Proxmox Cluster (Management VLAN 98)
    ├── 10.30.3.2 — Proxmox node 1
    ├── 10.30.3.3 — Proxmox node 2
    ├── 10.30.3.4 — Proxmox node 3
    └── 10.30.3.5 — Proxmox node 4
    VMs run in Services VLAN 50 and dual-homed into IoT VLAN 20 (HA only)

Kubernetes Cluster (Services VLAN 50)
    └── Cilium Gateway API
          ├── LoadBalancer IP: 10.30.50.200
          ├── HTTPRoutes → cluster services
          └── HTTPRoutes → non-cluster services (Proxmox, NAS, HA, Plex)

How clients reach services:
    Any device → resolves *.jaimenet.com → 10.30.50.200 (Gateway)
              → firewall allows [VLAN] → 10.30.50.200:443
              → Gateway proxies to backend
```

### Key Design Decisions

| Decision | Rationale |
|---|---|
| Proxmox nodes in Management, VMs in Services | Clean boundary: manage down, not up |
| K8s nodes in Services only | Gateway IP in Services; one firewall rule per VLAN covers all services |
| HA dual-homed: Services + IoT | Direct IoT device access without firewall rules |
| Media VLAN allowed to reach Gateway | TVs/Alexas reach Plex and any other permitted service via single rule |
| Single Gateway IP as entry point | One firewall rule per VLAN exposes every permitted service |
| UniFi built-in DNS (no Pi-hole) | UCG-Fiber handles custom records; simpler stack |
| Single wildcard cert `*.jaimenet.com` | One cert-manager Certificate covers all subdomains |

---

## 2. VLAN Design

### Address Plan

| VLAN | Name | Subnet | Gateway | DHCP Range | Purpose |
|---|---|---|---|---|---|
| 10 | Main | 10.30.10.0/23 | 10.30.10.1 | 10.30.10.10–10.30.11.200 | Laptops, phones, desktops |
| 20 | IoT | 10.30.20.0/23 | 10.30.20.1 | 10.30.20.10–10.30.21.200 | Smart home, cameras, printers |
| 30 | Media | 10.30.30.0/23 | 10.30.30.1 | 10.30.30.10–10.30.31.200 | TVs, Alexas, streaming sticks |
| 40 | Guest | 10.30.40.0/23 | 10.30.40.1 | 10.30.40.10–10.30.41.200 | Visitor wifi, isolated |
| 50 | Services | 10.30.50.0/23 | 10.30.50.1 | 10.30.50.50–10.30.51.150 | K8s, NAS, HA, Plex |
| 98 | Management | 10.30.2.0/23 | 10.30.2.1 | 10.30.2.10–10.30.3.1 | UCG, switches, APs, Proxmox |

### Reserved Static IPs

**VLAN 98 — Management**

| IP | Role |
|---|---|
| 10.30.2.1 | UCG-Fiber |
| 10.30.2.2–9 | Switches, APs |
| 10.30.3.2 | Proxmox node 1 |
| 10.30.3.3 | Proxmox node 2 |
| 10.30.3.4 | Proxmox node 3 |
| 10.30.3.5 | Proxmox node 4 |

**VLAN 50 — Services**

| IP | Role |
|---|---|
| 10.30.50.1 | UCG-Fiber gateway |
| 10.30.50.5 | Home Assistant (Services NIC) |
| 10.30.50.6 | Plex VM |
| 10.30.50.10–20 | Kubernetes control plane nodes |
| 10.30.50.21–49 | Kubernetes worker nodes |
| 10.30.50.200 | Cilium Gateway LoadBalancer IP |
| 10.30.50.201–220 | Cilium LB IPAM pool (additional LB IPs) |

**VLAN 20 — IoT**

| IP | Role |
|---|---|
| 10.30.20.1 | UCG-Fiber gateway |
| 10.30.20.5 | Home Assistant (IoT NIC — direct device control) |

---

## 3. UniFi Configuration

### 3.1 Networks (Settings → Networks)

| VLAN | Purpose setting | Client Isolation | DNS |
|---|---|---|---|
| 10 Main | Corporate | Off | 10.30.10.1 |
| 20 IoT | Corporate | Off | 10.30.20.1 |
| 30 Media | Corporate | Off | 10.30.30.1 |
| 40 Guest | Guest | On | 1.1.1.1, 8.8.8.8 |
| 50 Services | Corporate | Off | 10.30.50.1 |
| 98 Management | Corporate | Off | 10.30.2.1 |

Guest VLAN uses public DNS directly — no custom records needed there.

### 3.2 WiFi SSIDs

| SSID | VLAN | Band | Security |
|---|---|---|---|
| JaimeNet | Main (10) | 2.4 + 5 GHz | WPA3 |
| JaimeNet-IoT | IoT (20) | 2.4 GHz | WPA2 |
| JaimeNet-Media | Media (30) | 2.4 + 5 GHz | WPA2/WPA3 |
| JaimeNet-Guest | Guest (40) | 2.4 + 5 GHz | WPA2, client isolation ON |

Management (98) — wired only, no SSID.
Services (50) — wired only, no SSID.

### 3.3 Switch Port Profiles

| Profile | Mode | Native VLAN | Tagged VLANs |
|---|---|---|---|
| Management only | Access | 98 | — |
| Trunk (uplinks) | Trunk | — | 10, 20, 30, 40, 50, 98 |
| K8s Node | Access | 50 | — |
| NAS | Access | 50 | — |
| Plex VM | Access | 50 | — |
| Desktop (Main) | Access | 10 | — |
| Proxmox host | Trunk | 98 | 50, 20 |
| TV / streaming device | Access | 30 | — |

The Proxmox host switch port trunks VLANs 98 (its own management IP), 50 (K8s and HA primary NIC), and 20 (HA IoT subinterface).

### 3.4 DHCP Reservations

For all static IPs, use UniFi DHCP reservations rather than OS-level static config:

```
Settings → Networks → [Network] → DHCP → Fixed IP Assignments → Add
```

---

## 4. Internal DNS (UniFi Custom Records)

The UCG-Fiber acts as DNS resolver for all VLANs. All `*.jaimenet.com` subdomains resolve to the Gateway IP (`10.30.50.200`) so traffic stays internal.

### 4.1 Upstream Resolvers

```
UniFi → Settings → Internet → WAN → DNS
Primary:   1.1.1.1
Secondary: 9.9.9.9
```

### 4.2 Custom DNS Records

```
UniFi → Settings → DNS → Local DNS Records
```

| Hostname | IP |
|---|---|
| home.jaimenet.com | 10.30.50.200 |
| plex.jaimenet.com | 10.30.50.200 |
| grafana.jaimenet.com | 10.30.50.200 |
| prometheus.jaimenet.com | 10.30.50.200 |
| pve.jaimenet.com | 10.30.50.200 |
| nas.jaimenet.com | 10.30.50.200 |
| longhorn.jaimenet.com | 10.30.50.200 |
| argocd.jaimenet.com | 10.30.50.200 |
| uptime.jaimenet.com | 10.30.50.200 |
| *(add each new service here)* | 10.30.50.200 |

> **Note:** UniFi does not support wildcard DNS — each subdomain must be added individually when a new service is created.

### 4.3 Verify Resolution

From any device on VLANs 10, 20, 30, 50, or 98:

```bash
nslookup plex.jaimenet.com
# Expected: 10.30.50.200
```

---

## 5. Home Assistant — Dual-VLAN Setup

HA runs as a Docker container on a Linux VM hosted on Proxmox. It needs:

- **VLAN 50 (Services):** default gateway, internet access, exposed via Gateway
- **VLAN 20 (IoT):** direct on-link access to all IoT devices

It does **not** need VLANs 10, 30, 40, or 98. Main and Media users reach HA via `home.jaimenet.com` through the Gateway.

### 5.1 Architecture

```
Proxmox Node (VLAN 98: 10.30.3.x)
└── Home Assistant VM
      └── eth0 (trunk: VLAN 50 + VLAN 20)
            ├── eth0.50  →  10.30.50.5/23   Services (default GW: 10.30.50.1)
            └── eth0.20  →  10.30.20.5/23   IoT (on-link only, no GW)

Docker (--network host)
└── homeassistant container
```

### 5.2 Proxmox Configuration

**VLAN-aware bridge on Proxmox host:**

```ini
# /etc/network/interfaces
auto vmbr0
iface vmbr0 inet manual
    bridge-ports enp3s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
```

**VM config (`/etc/pve/qemu-server/<vmid>.conf`):**

```
net0: virtio=XX:XX:XX:XX:XX:XX,bridge=vmbr0,trunks=50;20
```

### 5.3 Linux VM Network Configuration

```bash
apt install vlan
echo "8021q" >> /etc/modules
```


```ini
# /etc/network/interfaces
auto eth0
iface eth0 inet manual

auto eth0.50
iface eth0.50 inet static
    address 10.30.50.5/23
    gateway 10.30.50.1
    vlan-raw-device eth0

auto eth0.20
iface eth0.20 inet static
    address 10.30.20.5/23
    vlan-raw-device eth0
```

Resulting routing table:

```
10.30.50.0/23 dev eth0.50    # Services — on-link
10.30.20.0/23 dev eth0.20    # IoT — on-link
0.0.0.0/0 via 10.30.50.1    # default via Services
```

### 5.4 Home Assistant Container

```yaml
# docker-compose.yml
services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./config:/config
```

### 5.5 Gateway Exposure

```yaml
# ha.yaml — external-services namespace
apiVersion: v1
kind: Service
metadata:
  name: home-assistant
  namespace: external-services
spec:
  clusterIP: None
  ports:
    - name: http
      port: 8123
---
apiVersion: v1
kind: Endpoints
metadata:
  name: home-assistant
  namespace: external-services
subsets:
  - addresses:
      - ip: 10.30.50.5
    ports:
      - name: http
        port: 8123
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: home-assistant
  namespace: external-services
spec:
  parentRefs:
    - name: main-gateway
      namespace: networking
      sectionName: https
  hostnames:
    - home.jaimenet.com
  rules:
    - backendRefs:
        - name: home-assistant
          port: 8123
```

---

## 6. Plex — Media VLAN Access

Plex runs on a VM in Services VLAN (`10.30.50.6`, port `32400`). It is exposed via the Cilium Gateway at `plex.jaimenet.com` using the wildcard cert.

### 6.1 How Media VLAN Devices Reach Plex

```
TV / Alexa / streaming stick (VLAN 30)
    → DNS: plex.jaimenet.com → 10.30.50.200 (Gateway)
    → Firewall: Media → 10.30.50.200:443 ✓
    → Gateway terminates TLS, proxies to 10.30.50.6:32400
```

No special Plex configuration needed — clients connect to `https://plex.jaimenet.com`. Plex's built-in LAN discovery (GDM, UDP 32414) does not cross VLANs, but all major clients (Apple TV, Fire Stick, Chromecast, Alexa) support direct server entry by URL.

### 6.2 Kubernetes Manifests

```yaml
# plex.yaml — external-services namespace
apiVersion: v1
kind: Service
metadata:
  name: plex
  namespace: external-services
spec:
  clusterIP: None
  ports:
    - name: http
      port: 32400
---
apiVersion: v1
kind: Endpoints
metadata:
  name: plex
  namespace: external-services
subsets:
  - addresses:
      - ip: 10.30.50.6
    ports:
      - name: http
        port: 32400
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: plex
  namespace: external-services
spec:
  parentRefs:
    - name: main-gateway
      namespace: networking
      sectionName: https
  hostnames:
    - plex.jaimenet.com
  rules:
    - backendRefs:
        - name: plex
          port: 32400
```

### 6.3 Firewall Rule

```
Allow: Media (10.30.30.0/23) → 10.30.50.200 (Gateway) port 443
```

This single rule gives Media VLAN access to Plex and any other service exposed via the Gateway. See §11 for full firewall matrix.

### 6.4 UniFi DNS Record

```
UniFi → Settings → DNS → Local DNS Records
plex.jaimenet.com → 10.30.50.200
```

### 6.5 Plex Client Configuration

On each streaming device, set the Plex server address manually:

```
Server URL: https://plex.jaimenet.com
```

- **Apple TV:** Plex app → Settings → Manually enter server address
- **Fire Stick:** Same — Plex app → Settings → Manually enter server
- **Alexa:** Plex skill connects via Plex account, no manual URL needed

---

## 7. Kubernetes: Cilium Gateway API

### 7.1 VLAN Placement

All Kubernetes nodes live in **VLAN 50 (Services) only**. The Cilium Gateway IP (`10.30.50.200`) is in Services. Firewall rules allow each VLAN to reach `10.30.50.200:443` as needed — one rule per VLAN covers every service behind the Gateway.

### 7.2 Prerequisites

```yaml
# cilium-values.yaml (Helm)
gatewayAPI:
  enabled: true
ipam:
  mode: kubernetes
l2announcements:
  enabled: true
```


```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml
```

### 7.3 Cilium LB IPAM Pool

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: homelab-pool
spec:
  cidrs:
    - cidr: 10.30.50.200/27   # .200–.231
```


```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: homelab-l2
spec:
  interfaces:
    - eth0
  externalIPs: false
  loadBalancerIPs: true
```

### 7.4 GatewayClass

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
```

### 7.5 Gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: networking
  annotations:
    cilium.io/lb-ipam-ips: "10.30.50.200"
spec:
  gatewayClassName: cilium
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: jaimenet-wildcard-tls
            namespace: networking
      allowedRoutes:
        namespaces:
          from: All
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
```

### 7.6 HTTP → HTTPS Redirect

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https-redirect
  namespace: networking
spec:
  parentRefs:
    - name: main-gateway
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

---

## 8. TLS: cert-manager + Let's Encrypt DNS-01

### 8.1 Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
```

### 8.2 Cloudflare API Token Secret

Scoped to **Zone → DNS → Edit** for `jaimenet.com` only:

```bash
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token=<YOUR_TOKEN>
```

### 8.3 ClusterIssuer

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: jaime@jaimenet.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

### 8.4 Wildcard Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: jaimenet-wildcard
  namespace: networking
spec:
  secretName: jaimenet-wildcard-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  commonName: "*.jaimenet.com"
  dnsNames:
    - "*.jaimenet.com"
    - "jaimenet.com"
  renewBefore: 720h
```

---

## 9. Ingress Routing Strategy

### 9.1 One HTTPRoute per Service

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  parentRefs:
    - name: main-gateway
      namespace: networking
      sectionName: https
  hostnames:
    - grafana.jaimenet.com
  rules:
    - backendRefs:
        - name: grafana
          port: 3000
```

### 9.2 Subdomain Map

| Subdomain | Backend | Type |
|---|---|---|
| home.jaimenet.com | HA (10.30.50.5:8123) | External |
| plex.jaimenet.com | Plex VM (10.30.50.6:32400) | External |
| grafana.jaimenet.com | Grafana pod | In-cluster |
| prometheus.jaimenet.com | Prometheus pod | In-cluster |
| pve.jaimenet.com | Proxmox (10.30.3.2:8006) | External |
| nas.jaimenet.com | NAS | External |
| longhorn.jaimenet.com | Longhorn UI pod | In-cluster |
| argocd.jaimenet.com | ArgoCD pod | In-cluster |
| uptime.jaimenet.com | Uptime Kuma pod | In-cluster |

---

## 10. Non-Cluster Services (External via Gateway)

```yaml
# proxmox.yaml — external-services namespace
apiVersion: v1
kind: Service
metadata:
  name: proxmox
  namespace: external-services
spec:
  clusterIP: None
  ports:
    - name: https
      port: 8006
---
apiVersion: v1
kind: Endpoints
metadata:
  name: proxmox
  namespace: external-services
subsets:
  - addresses:
      - ip: 10.30.3.2
    ports:
      - name: https
        port: 8006
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: proxmox
  namespace: external-services
spec:
  parentRefs:
    - name: main-gateway
      namespace: networking
      sectionName: https
  hostnames:
    - pve.jaimenet.com
  rules:
    - backendRefs:
        - name: proxmox
          port: 8006
```

### External Services Inventory

| Subdomain | Target IP | Port |
|---|---|---|
| home.jaimenet.com | 10.30.50.5 | 8123 |
| plex.jaimenet.com | 10.30.50.6 | 32400 |
| pve.jaimenet.com | 10.30.3.2 | 8006 |
| nas.jaimenet.com | 10.30.50.7 | 443 |

---

## 11. Firewall Rules

### 11.1 Default Deny Inter-VLAN

```
Rule: Default inter-VLAN deny
Source:      RFC1918
Destination: RFC1918
Action:      Drop
Priority:    Lowest
```

### 11.2 Allowed Traffic Matrix

| Source | Destination | Ports | Reason |
|---|---|---|---|
| Main (10) | Gateway (10.30.50.200) | 443, 80 | All services via Gateway |
| Main (10) | Management (98) | 8006, 22 | Direct Proxmox/UCG admin |
| Main (10) | IoT (20) | 5353/UDP | mDNS |
| Media (30) | Gateway (10.30.50.200) | 443 | Plex + all Services via Gateway |
| Management (98) | Services (50) | 22 | VM management from Proxmox |
| Management (98) | Internet | any | Updates, VPN, firmware |
| Services (50) | Internet | any | Image pulls, cert issuance |
| HA (10.30.50.5) | IoT (20) | any | On-link via eth0.20 — no rule needed |
| IoT (20) | HA Services IP (10.30.50.5) | — | **Blocked** |
| IoT (20) | Services (50) | — | **Blocked** |
| IoT (20) | Management (98) | — | **Blocked** |
| Media (30) | Management (98) | — | **Blocked** |
| Media (30) | IoT (20) | — | **Blocked** |
| Guest (40) | All internal | — | **Blocked** |

### 11.3 Internet Access

| VLAN | Internet | Notes |
|---|---|---|
| Main (10) | Yes | Normal browsing |
| IoT (20) | Yes (HTTP/HTTPS only) | Block unsolicited inbound |
| Media (30) | Yes | Streaming services, app updates |
| Guest (40) | Yes | Isolated |
| Services (50) | Yes | Image pulls, cert issuance |
| Management (98) | Yes | Updates, VPN, firmware |

### 11.4 External Access to jaimenet.com

- **WireGuard VPN on UCG-Fiber** — recommended
- **Cloudflare Tunnel** — works behind CGNAT, no port forwarding
- **Port forward 443 → 10.30.50.200** — simplest but exposes Gateway publicly

---

## 12. Security Hardening

### 12.1 Network Checklist

- [ ] IoT cannot reach Services, Management, or HA's Services IP
- [ ] Media can only reach Gateway IP — not raw Services subnet
- [ ] Guest is fully isolated
- [ ] Management and Services are wired-only (no WiFi SSIDs)
- [ ] All user-facing services behind `*.jaimenet.com` with valid TLS

### 12.2 Home Assistant

- [ ] Enable 2FA for admin accounts
- [ ] HA has no NIC on Management — Proxmox nodes not directly reachable from HA
- [ ] Review add-ons — each runs with broad network access via host networking

### 12.3 Kubernetes

- [ ] RBAC — minimal ServiceAccount permissions per namespace
- [ ] Cilium NetworkPolicies — default deny within namespaces
- [ ] K8s API server not reachable outside Services VLAN
- [ ] Cloudflare API token in sealed-secrets or external-secrets

### 12.4 TLS

- [ ] Wildcard cert auto-renews (`renewBefore: 720h`)
- [ ] Staging issuer tested before production
- [ ] Monitor expiry: `kubectl get certificate -A`

---

## 13. Operational Runbook

### Add a New Kubernetes Service

1. Deploy service and `Service` object in its namespace.
2. Create `HTTPRoute` referencing `main-gateway` in `networking`.
3. Add UniFi DNS record: `myservice.jaimenet.com → 10.30.50.200`.
4. Test: `curl https://myservice.jaimenet.com` from Main VLAN.

### Add a New Non-Cluster Service

1. Assign static IP via UniFi DHCP reservation.
2. Create `Service` + `Endpoints` in `external-services` (§10 pattern).
3. Create `HTTPRoute`.
4. Add UniFi DNS record.

### Add a New IoT Device

No changes needed. Device goes on VLAN 20, HA discovers it via `eth0.20`.

### Add a New Media Device (TV, Alexa, etc.)

Connect to `JaimeNet-Media` SSID or assign a wired port to VLAN 30. Configure Plex client with server URL `https://plex.jaimenet.com`. No firewall changes needed — the Media → Gateway rule already covers it.

### Renew Wildcard Certificate (Manual)

```bash
kubectl annotate certificate jaimenet-wildcard -n networking \
  cert-manager.io/force-renewal="true"
```

### Debug TLS Issues

```bash
kubectl describe certificate jaimenet-wildcard -n networking
kubectl get order,challenge -n networking
dig TXT _acme-challenge.jaimenet.com @1.1.1.1
```

### Useful kubectl Commands

```bash
kubectl get httproute -A
kubectl get gateway -A
kubectl get certificate -A
kubectl get ciliumloadbalancerippool
kubectl get endpoints -n external-services
```

---

## Appendix: File/Resource Inventory

```
k8s/
├── networking/
│   ├── namespace.yaml
│   ├── gatewayclass.yaml
│   ├── gateway.yaml
│   ├── http-redirect.yaml
│   └── wildcard-cert.yaml
├── cert-manager/
│   ├── cluster-issuer-staging.yaml
│   ├── cluster-issuer-prod.yaml
│   └── cloudflare-secret.yaml        # ← DO NOT COMMIT
├── cilium/
│   ├── lb-pool.yaml
│   └── l2-announcement.yaml
├── external-services/
│   ├── namespace.yaml
│   ├── home-assistant.yaml
│   ├── plex.yaml
│   ├── proxmox.yaml
│   └── nas.yaml
└── apps/
    ├── monitoring/
    │   ├── grafana-route.yaml
    │   ├── prometheus-route.yaml
    │   └── uptime-kuma-route.yaml
    ├── longhorn/
    │   └── longhorn-route.yaml
    └── argocd/
        └── argocd-route.yaml
```

---

*Document version: June 2026 — jaimenet.com homelab*
