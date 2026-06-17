# Chapter 12 — Upgrades & Next Steps

**Goal:** Know how to upgrade Kubernetes safely, and have a clear decision framework
for which cluster capability to add next.

**You will learn:** The Kubernetes upgrade path, how Kubespray handles upgrades,
and the trade-offs between the three next-step options (ingress, storage, HA).

**Prerequisites:** [Chapter 09 — Operations Runbook](09-operations-runbook.md).
Your cluster should be healthy and stable before planning any expansion.

**Where to run commands:**

| Task | Run on |
|---|---|
| Edit Kubespray version / config | Your workstation (git) |
| Trigger upgrade or deploy workflow | Forgejo web UI |
| Take VM snapshots before upgrade | Proxmox web UI |
| Verify Kubernetes version after upgrade | LXC-Rocky10 |
| Check pods, PVCs, Ingress resources | LXC-Rocky10 |

---

## Kubernetes upgrades

### The rules

- **One minor version at a time.** `v1.31 → v1.32` is valid. `v1.31 → v1.33` is not.
- **Kubespray version and kube_version must stay aligned.** Each Kubespray
  release supports a specific range of Kubernetes versions — check the
  Kubespray release notes before updating either.
- **Always take a snapshot first** (Proxmox UI → VM → Snapshots → Take snapshot).
  Kubernetes upgrades on kubeadm-based clusters are not trivially reversible.

### Procedure

**Step 1 — Find the matching versions.**

Check https://github.com/kubernetes-sigs/kubespray/releases for the release
that supports your target `kube_version`. For example:

| kube_version | Kubespray tag |
|---|---|
| v1.31.4 | v2.26.0 (current) |
| v1.32.x | v2.27.x |
| v1.33.x | v2.28.x (check release notes) |

**Step 2 — Snapshot all VMs.**

In Proxmox UI, take a snapshot of VMs 201, 202, 203. Label them with the
current K8s version, e.g. `pre-upgrade-v1.31.4`.

**Step 3 — Update the repo.**

In `ansible/inventory/group_vars/all/kubespray.yml`:
```yaml
kube_version: v1.32.0   # new target version
```

In `.forgejo/workflows/ansible-deploy.yml`:
```yaml
git clone --branch v2.27.0 --depth 1 \   # matching Kubespray tag
  https://github.com/kubernetes-sigs/kubespray.git ansible/kubespray
```

Commit and push.

**Step 4 — Trigger the upgrade.**

Forgejo → Actions → **Ansible — Deploy K8s Cluster** → Run workflow.

Set `kubespray_tags` to `upgrade` to run only the upgrade tasks, not a full
cluster reinstall.

**Step 5 — Verify.**

```bash
kubectl get nodes
# Should show v1.32.0 on all nodes

kubectl get pods -A | grep -v Running | grep -v Completed
# Should be empty
```

**Step 6 — Delete snapshots** once you're satisfied. Old snapshots consume
disk space on your Proxmox datastore.

---

## Next capabilities: choose one

The cluster currently has no ingress, no persistent storage, and a single
control plane node. Below is the decision framework for what to add next.

---

### Option A — Ingress-nginx (recommended first step)

**Effort:** Low — one config change, one workflow run.
**Why first:** Lets you expose services with domain names and TLS. Required
for almost every real workload you'll want to demo.

**What it does:** Deploys an NGINX ingress controller as a DaemonSet.
Any `Ingress` resource you create will be routed through it.

**How to enable:**

In `ansible/inventory/group_vars/all/kubespray.yml`:
```yaml
ingress_nginx_enabled: true
ingress_nginx_host_network: true   # needed for bare-metal (no cloud LoadBalancer)
```

Trigger `ansible-deploy` with `kubespray_tags: apps`.

**After enabling**, you can create ingress resources. Traffic to any worker
node IP on port 80/443 will be handled by NGINX. For a single entry point,
point a local DNS entry or `/etc/hosts` at `192.168.1.202` or `.203`.

**Limitations:** No automatic TLS cert issuing (add cert-manager separately).
No single stable IP without kube-vip or MetalLB (add with HA or storage step).

---

### Option B — Persistent storage via NFS (medium effort)

**Effort:** Medium — TrueNAS config + Helm chart + StorageClass.
**Why second:** Needed for any stateful workload (databases, Prometheus, etc.).

**What it does:** Uses TrueNAS NFS exports as a storage backend. An
`nfs-subdir-external-provisioner` running in the cluster automatically creates
an NFS subdirectory for each `PersistentVolumeClaim`.

**Step 1 — TrueNAS side:**

- Create an NFS dataset, e.g. `tank/k8s-pvc`
- Add an NFS share for it
- Grant network access to the K8s VM subnet (`192.168.1.0/24`)
- Note the TrueNAS IP and export path

**Step 2 — Cluster side:**

```bash
helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/

helm install nfs-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --set nfs.server=192.168.1.50 \
  --set nfs.path=/mnt/tank/k8s-pvc \
  --set storageClass.name=nfs-standard \
  --set storageClass.defaultClass=true \
  -n kube-system
```

**Step 3 — Verify:**

```bash
kubectl get storageclass
# Should show: nfs-standard (default)

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 1Gi
EOF

kubectl get pvc test-pvc
# Should be Bound within 30 seconds
```

---

### Option C — HA control plane (high effort)

**Effort:** High — new VM, Kubespray reconfiguration, kube-vip.
**Why third:** Protects against control plane downtime. Not needed until
the cluster is serving something you care about not losing.

**What it does:** Adds a second control plane node (VM 204) and a virtual
IP (`kube_apiserver_ip`) managed by kube-vip. If one control plane goes
down, the other takes over. etcd becomes a three-node cluster (two CPs +
one external, or two CPs sharing etcd — check Kubespray docs for the
current recommendation).

**Prerequisites:**

- Add VM 204 (`k8s-cp-02`, 2 vCPU, 4 GB, `192.168.1.204`) to Terraform
- Choose a VIP for the API server, e.g. `192.168.1.100` (careful — that's
  the Proxmox host; use something unused, e.g. `192.168.1.210`)
- Add `kube-vip` to the Kubespray config

**Key config changes in `kubespray.yml`:**
```yaml
kube_apiserver_ip: 192.168.1.210   # VIP, managed by kube-vip
loadbalancer_apiserver:
  address: 192.168.1.210
  port: 6443
kube_vip_enabled: true
kube_vip_controlplane_enabled: true
```

This is a destructive change — existing kubeconfigs will need updating to
use the new VIP. Test on a fresh cluster first.

---

## Suggested sequence

If you're unsure which to start with:

```
1. Ingress-nginx    → now you can expose services
2. Persistent storage → now you can run databases
3. HA control plane → now you can lose a node without panic
```

Each builds on the previous. Don't skip ahead to HA before you have
workloads worth protecting.

---

## Future reference docs

Once you add a capability, document it in a new chapter following the same
format: Goal → You will learn → Prerequisites → Where to run commands → Steps →
Expected output → Checkpoint questions → Common mistakes.

Suggested chapter numbers:
- `13-ingress-nginx.md`
- `14-persistent-storage.md`
- `15-ha-control-plane.md`

---

## Checkpoint questions

1. Why must Kubernetes be upgraded one minor version at a time?
2. What should you snapshot before a cluster upgrade, and why?
3. Why must the Kubespray tag and `kube_version` always be updated together?
4. Of the three next-step options, which is recommended first and why?
5. Why is HA control plane not the first recommended expansion?

## Common mistakes

| Mistake | Why it matters | Fix |
|---|---|---|
| Skipping minor versions (e.g. v1.31 → v1.33) | Unsupported upgrade path — kubeadm will refuse or leave the cluster broken | Upgrade one minor version at a time |
| No Proxmox snapshot before upgrade | Failed upgrades are hard to roll back | Snapshot VMs 201–203 before every upgrade |
| Updating `kube_version` without checking Kubespray support | Kubespray may not test or support the target version | Check Kubespray release notes before updating either value |
| Adding HA control plane before ingress or storage | Adds significant complexity before the cluster hosts useful workloads | Add ingress first, then storage, then HA |
| Using the Proxmox host IP (`192.168.1.100`) as the API VIP | IP conflict — the Proxmox API and the K8s API will fight for the same address | Pick an unused LAN IP, e.g. `192.168.1.210` |

---

*Previous: [Chapter 11 — Security & Key Rotation](11-security-key-rotation.md) · Back to: [Lab Overview](00-lab-overview.md)*
