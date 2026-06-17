# Chapter 08 — kubectl Access

**Goal:** `kubectl get nodes` works from LXC-Rocky10 and shows all three nodes
Ready. The kubeconfig lives at `~/.kube/homelab.yaml` and survives shell restarts.

**You will learn:** How kubeconfig files work, why the control plane IP must be
patched into the kubeconfig, and how to verify every layer of the cluster is healthy.

**Prerequisites:** [Chapter 07 — Ansible & Kubespray](07-ansible-kubespray.md).
The `ansible-deploy` workflow must have completed with `failed=0` on all nodes
and the kubeconfig artifact must be downloadable.

**Where to run commands:**

| Step | Run on | User |
|---|---|---|
| Download kubeconfig artifact | Forgejo web UI / your workstation | any |
| Copy kubeconfig to LXC-Rocky10 | Your workstation → LXC-Rocky10 | `root` on LXC |
| Install kubectl | LXC-Rocky10 | `root` |
| Set `KUBECONFIG` permanently | LXC-Rocky10 | `root` |
| Verification commands | LXC-Rocky10 | `root` |

---

## What is a kubeconfig file?

Before touching any files, understand what you are about to set up.

A kubeconfig is a single YAML file that bundles three things kubectl needs:

| What | Why kubectl needs it |
|---|---|
| API server address | Where to send requests — `https://192.168.1.201:6443` |
| CA certificate | Proves the cluster is genuine, not an impostor |
| Client certificate + key | Proves *you* are an authorised cluster admin |

Without this file kubectl has no idea where the cluster is or whether it
should trust it. Think of it as a combined address book entry and ID card
for the cluster.

Kubernetes generates this file during installation and stores it on the
control plane at `/etc/kubernetes/admin.conf`. The server address inside
it is `127.0.0.1:6443` — correct on the control plane itself, but
unreachable from your admin host. Our `post-k8s.yml` playbook automatically:

1. Copies it off the control plane
2. Patches the server address to `192.168.1.201:6443` (the real LAN IP)
3. Saves it as `kubeconfig/homelab.yaml` on the runner
4. Uploads it as a Forgejo artifact (`kubeconfig-homelab`) so you can
   download it without SSH-ing into the runner

> **After a cluster rebuild:** every rebuild generates new certificates.
> The old kubeconfig will immediately stop working with an x509 error.
> The fix is always the same: download the fresh artifact from the latest
> `ansible-deploy` run.

---

## Step 1 — Download the kubeconfig artifact

After `ansible-deploy` completes, open the workflow run page in Forgejo. Scroll
to the **Artifacts** section at the bottom and download `kubeconfig-homelab`.

This gives you a `homelab.yaml` file. It already has the control plane IP
(`192.168.1.201:6443`) patched in — `post-k8s.yml` did this automatically.

---

## Step 2 — Install kubectl on LXC-Rocky10

SSH into the LXC-Rocky10 container:

```bash
ssh root@<lxc-rocky10-ip>
```

Install kubectl (Rocky Linux 10 uses dnf):

```bash
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
EOF

dnf install -y kubectl
kubectl version --client
```

Expected output:
```
Client Version: v1.31.x
Kustomize Version: v5.x.x
```

---

## Step 3 — Place the kubeconfig

```bash
mkdir -p ~/.kube

# Option A: paste the file content directly
cat > ~/.kube/homelab.yaml << 'EOF'
<paste contents of homelab.yaml here>
EOF

# Option B: scp from your workstation
# (run this from your workstation, not LXC-Rocky10)
scp ~/Downloads/homelab.yaml root@<lxc-rocky10-ip>:~/.kube/homelab.yaml
```

Set permissions:

```bash
chmod 600 ~/.kube/homelab.yaml
```

---

## Step 4 — Set KUBECONFIG permanently

```bash
echo 'export KUBECONFIG=~/.kube/homelab.yaml' >> ~/.bashrc
source ~/.bashrc
```

Verify the variable is set:

```bash
echo $KUBECONFIG
# Should print: /root/.kube/homelab.yaml
```

---

## Step 5 — Verify the cluster

Run each of these and confirm the expected output:

### Nodes

```bash
kubectl get nodes -o wide
```

Expected:
```
NAME            STATUS   ROLES           AGE   VERSION   INTERNAL-IP       OS-IMAGE             KERNEL-VERSION
k8s-cp-01       Ready    control-plane   Xm    v1.31.4   192.168.1.201   Ubuntu 24.04.x LTS   6.x.x-generic
k8s-worker-01   Ready    <none>          Xm    v1.31.4   192.168.1.202   Ubuntu 24.04.x LTS   6.x.x-generic
k8s-worker-02   Ready    <none>          Xm    v1.31.4   192.168.1.203   Ubuntu 24.04.x LTS   6.x.x-generic
```

All three nodes must show `Ready`. If any shows `NotReady`, see Chapter 10.

---

### System pods

```bash
kubectl get pods -n kube-system
```

Every pod should be `Running` or `Completed`. Key pods to confirm:

| Pod name prefix | What it does |
|---|---|
| `calico-node-*` | CNI — one per node, all must be Running |
| `calico-kube-controllers-*` | Manages Calico network policy |
| `coredns-*` | Cluster DNS |
| `etcd-k8s-cp-01` | Key-value store — single instance (not HA) |
| `kube-apiserver-k8s-cp-01` | Kubernetes API |
| `kube-controller-manager-k8s-cp-01` | Reconciliation loop |
| `kube-scheduler-k8s-cp-01` | Pod scheduling |
| `kube-proxy-*` | Network rules — one per node |
| `metrics-server-*` | Resource usage metrics |

---

### Resource usage (confirms Metrics Server)

```bash
kubectl top nodes
```

Expected (approximate, will vary):
```
NAME            CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
k8s-cp-01       120m         6%     1800Mi          46%
k8s-worker-01   50m          2%     900Mi           15%
k8s-worker-02   50m          2%     900Mi           15%
```

If this command hangs or returns `ServiceUnavailable`, the Metrics Server is not
ready yet — wait 2 minutes and retry.

---

### API server reachability

```bash
kubectl cluster-info
```

Expected:
```
Kubernetes control plane is running at https://192.168.1.201:6443
CoreDNS is running at https://192.168.1.201:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

---

## Managing multiple kubeconfigs (optional)

If you later add more clusters, use `KUBECONFIG` merging instead of replacing
the file:

```bash
export KUBECONFIG=~/.kube/homelab.yaml:~/.kube/other-cluster.yaml
kubectl config get-contexts
kubectl config use-context homelab
```

For now, with a single cluster, the simple `export KUBECONFIG=~/.kube/homelab.yaml`
in `.bashrc` is all you need.

---

## After a cluster rebuild

Every time the cluster is rebuilt (fresh `ansible-deploy` after a `terraform destroy` +
`apply`), the cluster certificates change. The old kubeconfig will stop working
immediately with:

```
error: You must be logged in to the server (Unauthorized)
```

or:

```
Unable to connect to the server: x509: certificate signed by unknown authority
```

Fix: download the new kubeconfig artifact from the latest `ansible-deploy` run
and overwrite `~/.kube/homelab.yaml`. No other action needed.

---

## Checkpoint questions

1. Why does the kubeconfig server URL say `192.168.1.201:6443` and not `127.0.0.1:6443`?
2. After a cluster rebuild, `kubectl get nodes` returns an x509 error. What is the cause and fix?
3. `kubectl top nodes` returns `error: Metrics API not available`. What does this mean, and how would you check?
4. Why must `~/.kube/homelab.yaml` have permission `600` and not `644`?
5. You log out and back in to LXC-Rocky10 and `kubectl` no longer works. Why, and what did you forget?

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| `KUBECONFIG` set in shell session only, not `.bashrc` | Works now, breaks on re-login | Add `export KUBECONFIG=...` to `~/.bashrc` |
| Kubeconfig downloaded but server URL still `127.0.0.1` | Connection refused (nothing listening on localhost) | Ensure `post-k8s.yml` ran; re-trigger `ansible-deploy` |
| File permissions `644` on kubeconfig | kubectl warns and may refuse to use the file | `chmod 600 ~/.kube/homelab.yaml` |
| Old kubeconfig kept after cluster rebuild | x509 / Unauthorized errors | Download fresh artifact from latest workflow run |
| kubectl version not matching cluster | Some API fields may differ | Install the matching kubectl for the cluster version |

---

*Previous: [Chapter 07 — Ansible & Kubespray](07-ansible-kubespray.md) · Next: [Chapter 09 — Operations Runbook](09-operations-runbook.md)*
