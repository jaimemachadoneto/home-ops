# Kubernetes Cluster Startup Procedure

**Date Shutdown:** 2026-03-01
**Cluster:** home-ops (4-node Talos cluster with Rook-Ceph storage)

## Cluster Configuration Summary

- **Control-plane nodes:** home-ops-00 (10.30.4.1), home-ops-01 (10.30.4.2), home-ops-02 (10.30.4.3)
- **Worker nodes:** home-ops-03 (10.30.4.4)
- **Storage:** Rook-Ceph (3-way replication across home-ops-00, home-ops-01, home-ops-02)
- **Ceph OSDs:** 3 OSDs on `/dev/sdb` (1 per control-plane node)

## Pre-Shutdown State

- All nodes cordoned
- Flux controllers scaled to 0
- Ceph flags set: noout, norebalance, nobackfill, norecover
- Ceph health: HEALTH_OK
- All nodes drained and shut down gracefully

## Startup Procedure

### Step 1: Power On Nodes (IN ORDER)

Power on nodes in this specific order, waiting for each to fully boot before starting the next:

1. **home-ops-00** (10.30.4.1) - Wait 2-3 minutes for full boot
2. **home-ops-01** (10.30.4.2) - Wait 2-3 minutes for full boot
3. **home-ops-02** (10.30.4.3) - Wait 2-3 minutes for full boot
4. **home-ops-03** (10.30.4.4) - Wait 2-3 minutes for full boot

### Step 2: Verify Node Status

```bash
# Check all nodes are Ready
kubectl get nodes

# Expected output: All nodes should show STATUS=Ready
# NAME          STATUS   ROLES           AGE   VERSION
# home-ops-00   Ready    control-plane   XXd   v1.35.1
# home-ops-01   Ready    control-plane   XXd   v1.35.1
# home-ops-02   Ready    control-plane   XXd   v1.35.1
# home-ops-03   Ready    <none>          XXd   v1.35.1
```

If nodes don't appear Ready, check Talos status:
```bash
talosctl -n 10.30.4.1,10.30.4.2,10.30.4.3,10.30.4.4 health
```

### Step 3: Verify Ceph Cluster Status

```bash
# Check Ceph cluster status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

# Look for:
# - 3 mon daemons running
# - 3 OSDs up and in
# - All PGs should become active+clean (may take a few minutes)
```

Monitor Ceph pods:
```bash
kubectl -n rook-ceph get pods -o wide
```

Wait until all Ceph pods are Running and Ready (especially mon, mgr, and osd pods).

### Step 4: Remove Ceph Maintenance Flags

Once Ceph cluster is healthy, remove the maintenance flags:

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd unset noout
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd unset norebalance
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd unset nobackfill
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd unset norecover
```

Verify flags are unset:
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd dump | grep flags
```

### Step 5: Verify Ceph Health

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

Expected output:
- `health: HEALTH_OK`
- All PGs should be `active+clean`
- All 3 OSDs should be `up` and `in`

If you see HEALTH_WARN, check the specific warnings. Common warnings after restart:
- Clock skew - should resolve automatically
- Slow OSD heartbeats - temporary during startup
- PGs not scrubbed - will resolve over time

### Step 6: Uncordon All Nodes

```bash
kubectl uncordon home-ops-00 home-ops-01 home-ops-02 home-ops-03
```

Verify:
```bash
kubectl get nodes
# All nodes should show "Ready" with no "SchedulingDisabled" status
```

### Step 7: Scale Up Flux Controllers

```bash
kubectl -n flux-system scale deployment/source-controller --replicas=1
kubectl -n flux-system scale deployment/kustomize-controller --replicas=1
kubectl -n flux-system scale deployment/helm-controller --replicas=1
kubectl -n flux-system scale deployment/notification-controller --replicas=1
```

Verify Flux is running:
```bash
kubectl -n flux-system get pods
```

### Step 8: Monitor Cluster Recovery

Watch for pods to be rescheduled and start:
```bash
# Watch all pods
kubectl get pods -A

# Check for any pods in Error/CrashLoopBackOff state
kubectl get pods -A | grep -v Running | grep -v Completed

# Check PVCs are bound
kubectl get pvc -A | grep -v Bound
```

### Step 9: Verify Critical Services

Check that critical services are running:

```bash
# Ingress controllers
kubectl -n network get pods -l app.kubernetes.io/name=ingress-nginx

# Database
kubectl -n database get pods

# Monitor stack
kubectl -n observability get pods

# Media services
kubectl -n media get pods
kubectl -n downloads get pods
```

## Troubleshooting

### Nodes Not Coming Ready

```bash
# Check Talos service status
talosctl -n 10.30.4.X service

# Check logs
talosctl -n 10.30.4.X dmesg
talosctl -n 10.30.4.X logs kubelet
```

### Ceph Not Healthy

```bash
# Check OSD status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree

# Check OSD logs
kubectl -n rook-ceph logs -l app=rook-ceph-osd --tail=100

# Check mon logs
kubectl -n rook-ceph logs -l app=rook-ceph-mon --tail=100
```

If OSDs won't start, check that `/dev/sdb` is available on each control-plane node.

### PVCs Not Binding

```bash
# Check storage classes
kubectl get storageclass

# Check PV/PVC status
kubectl get pv,pvc -A

# If using Ceph, verify RBD provisioner is running
kubectl -n rook-ceph get pods -l app=csi-rbdplugin-provisioner
```

### Pods Stuck in Pending

```bash
# Describe the pod to see why it's pending
kubectl describe pod <pod-name> -n <namespace>

# Common reasons:
# - Node not ready
# - PVC not bound
# - Insufficient resources
# - Pod anti-affinity rules
```

## Network Configuration Changes

**IMPORTANT:** If the network configuration changed at the new location (different subnet, IPs, etc.), you'll need to update:

1. **Talos node IPs** - Update node addresses in Talos config
2. **Rook-Ceph network ranges** - Update `addressRanges` in HelmRelease if subnet changed
3. **Ingress/LoadBalancer IPs** - Update any external IPs
4. **DNS records** - Update DNS for any services

Consult Talos and Rook-Ceph documentation for network reconfiguration procedures.

## Post-Startup Checklist

- [ ] All nodes show Ready
- [ ] Ceph cluster shows HEALTH_OK
- [ ] All Ceph OSDs are up and in
- [ ] Ceph maintenance flags removed
- [ ] All nodes uncordoned
- [ ] Flux controllers running
- [ ] All critical pods running
- [ ] All PVCs bound
- [ ] Ingress working (test with curl/browser)
- [ ] External services accessible

## Reference Information

### Important Pod Counts

Monitor that these approximate pod counts return after startup:
- rook-ceph namespace: ~20+ pods (3 mons, 3 osds, mgrs, mds, csi plugins, etc.)
- kube-system namespace: ~15+ pods
- observability namespace: ~30+ pods
- flux-system namespace: ~4 pods (after scaling up)

### Storage Information

- **Ceph cluster ID:** 1329dd0c-7892-42f0-b348-9c3da719836a
- **Ceph pools:** 4 pools with 81 PGs
- **Total storage:** ~1 TiB raw (3 x 360GB OSDs)
- **Usable storage:** ~340 GiB (with 3-way replication)
- **Data usage at shutdown:** ~41 GiB used

### Contact Commands

```bash
# Get cluster info
kubectl cluster-info

# Get Ceph cluster details
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph -s

# View Ceph dashboard (if configured)
kubectl -n rook-ceph get service rook-ceph-mgr-dashboard
```

## Notes

- **Shutdown date:** 2026-03-01
- **Reason:** Physical relocation of cluster nodes
- **Ceph data integrity:** All data protected with 3-way replication
- **Expected recovery time:** 15-30 minutes after power-on

---

**Created by:** Claude Code Assistant
**Last updated:** 2026-03-01
