# Chapter 09 — Operations Runbook

**Goal:** Reference guide for day-to-day and incident operations. Every procedure
is self-contained — you should be able to execute any section without context from the others.

**You will learn:** How to keep the cluster healthy, how to respond to common failures,
and how to do routine maintenance without breaking things.

**Prerequisites:** [Chapter 08 — kubectl Access](08-kubectl-access.md). You should have
a working kubectl setup before attempting any procedure here.

**Where to run commands:**

| Task | Run on |
|---|---|
| `kubectl` commands | LXC-Rocky10 |
| SSH to K8s nodes | Your workstation or LXC-Rocky10 (via `k8s_ansible` key) |
| Proxmox `qm` commands | Proxmox host |
| Workflow triggers | Forgejo web UI |
| `terraform state` commands | Runner LXC workspace |

---


## Day-to-day access

### What you need to talk to the cluster

Kubernetes does not have a traditional login screen. You manage it from your
workstation using a command-line tool called **kubectl**. kubectl sends API
requests to the cluster over HTTPS — you never need to SSH in for normal
operations.

Two things are required before kubectl works:

1. **kubectl installed** on your workstation
2. **A kubeconfig file** — a YAML file that tells kubectl where the cluster is
   and proves who you are

#### Where kubectl runs in this homelab

kubectl is installed on **LXC-Rocky10** (`root@LXC-Rocky10`), a Rocky Linux 10
LXC container on the Proxmox host. This is the designated admin workstation for
the cluster — not a K8s node itself, just a management host that can reach the
cluster network.

The kubeconfig is placed at `/tmp/homelab.yaml` on that LXC after downloading
the artifact. For day-to-day use, move it somewhere permanent:

```bash
mkdir -p ~/.kube
mv /tmp/homelab.yaml ~/.kube/homelab.yaml
export KUBECONFIG=~/.kube/homelab.yaml
```

#### Install kubectl (one-time)

**Rocky Linux / RHEL / AlmaLinux (LXC-Rocky10)**:

```bash
# Download the latest stable release
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl
```

**Debian/Ubuntu**:

```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl
```

**Windows** (PowerShell):

```powershell
winget install Kubernetes.kubectl
```

**Mac**:

```bash
brew install kubectl
```

Verify on any platform:

```bash
kubectl version --client
```

> For a full explanation of what a kubeconfig file is and how it is generated,
> see [Chapter 08 — kubectl Access](08-kubectl-access.md). The steps below
> assume kubectl is already installed and the kubeconfig has been downloaded
> at least once. If this is your first time, complete Chapter 08 first.

#### Download the kubeconfig

1. Forgejo → **Actions** tab
2. Left sidebar → **Ansible — Deploy K8s Cluster**
3. Click the most recent successful run (green tick)
4. Scroll to the bottom of the run page → **Artifacts** section
5. Click `kubeconfig-homelab` → downloads a zip
6. Extract `homelab.yaml` from the zip

Save it somewhere permanent on your workstation, for example:

```
Windows:  C:\Users\<you>\.kube\homelab.yaml
Linux/Mac: ~/.kube/homelab.yaml
```

> **Never commit this file to the repo.** It grants full cluster admin access
> to whoever holds it. It is in `.gitignore` for this reason.

#### Use kubectl

```bash
# Explicit kubeconfig flag (useful when managing multiple clusters)
kubectl --kubeconfig ~/.kube/homelab.yaml get nodes

# Or export for the session so you don't need the flag every time
export KUBECONFIG=~/.kube/homelab.yaml
kubectl get nodes
kubectl get pods -A
```

**Verified baseline output — healthy cluster** (expected after fresh install with v1.31.4):

```
[root@LXC-Rocky10 ~]# kubectl --kubeconfig homelab.yaml get nodes
NAME            STATUS   ROLES           AGE    VERSION
k8s-cp-01       Ready    control-plane   129m   v1.31.4
k8s-worker-01   Ready    <none>          128m   v1.31.4
k8s-worker-02   Ready    <none>          128m   v1.31.4

[root@LXC-Rocky10 ~]# kubectl --kubeconfig homelab.yaml get pods -A
NAMESPACE     NAME                                      READY   STATUS    RESTARTS   AGE
kube-system   calico-kube-controllers-b5f8f6849-t959j   1/1     Running   0          127m
kube-system   calico-node-fhsvn                         1/1     Running   0          128m
kube-system   calico-node-hc57m                         1/1     Running   0          128m
kube-system   calico-node-k5lsf                         1/1     Running   0          128m
kube-system   coredns-776bb9db5d-dn4gs                  1/1     Running   0          127m
kube-system   coredns-776bb9db5d-kz59r                  1/1     Running   0          127m
kube-system   dns-autoscaler-6ffb84bd6-x6vc9            1/1     Running   0          127m
kube-system   kube-apiserver-k8s-cp-01                  1/1     Running   0          129m
kube-system   kube-controller-manager-k8s-cp-01         1/1     Running   1          129m
kube-system   kube-proxy-chvck                          1/1     Running   0          128m
kube-system   kube-proxy-fq5pw                          1/1     Running   0          128m
kube-system   kube-proxy-wv54f                          1/1     Running   0          128m
kube-system   kube-scheduler-k8s-cp-01                  1/1     Running   1          129m
kube-system   nginx-proxy-k8s-worker-01                 1/1     Running   0          128m
kube-system   nginx-proxy-k8s-worker-02                 1/1     Running   0          127m
kube-system   nodelocaldns-29nws                        1/1     Running   0          127m
kube-system   nodelocaldns-5bkgf                        1/1     Running   0          127m
kube-system   nodelocaldns-7b8c2                        1/1     Running   0          127m
```

All three nodes `Ready`, all system pods `Running` — this is what a healthy
cluster looks like. The two `RESTARTS: 1` on kube-controller-manager and
kube-scheduler are normal; they restart once during initial cluster bootstrap.

> **Note:** `kube-controller-manager` and `kube-scheduler` run only on the
> control plane (`k8s-cp-01`). The `nginx-proxy-*` pods run on workers as a
> local reverse proxy to the API server — this is a Kubespray default for
> non-HA clusters so workers can reach the API server reliably.

If you rebuilt the cluster (destroy + apply + ansible-deploy), download a fresh
kubeconfig — the old one's certificates will no longer match the new cluster.

---

### SSH to the control plane

Only needed for low-level debugging: inspecting systemd units, reading etcd
logs, or anything not exposed via kubectl. For all normal operations use
kubectl from your workstation instead.

```bash
ssh -i ~/.ssh/k8s_ansible ubuntu@192.168.1.201
```

| Detail | Value |
|---|---|
| Key | `~/.ssh/k8s_ansible` (Ansible keypair — not the Proxmox key) |
| User | `ubuntu` (created by cloud-init, has passwordless sudo) |
| Host | `192.168.1.201` (k8s-cp-01) |

Once on the control plane, kubectl is available as root. The kubeconfig
Kubespray installs on the node lives at `/etc/kubernetes/admin.conf`:

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes
# or drop to root for the session
sudo -i
kubectl get nodes
```

---

### SSH to worker nodes

Same key and user, different IP:

```bash
ssh -i ~/.ssh/k8s_ansible ubuntu@192.168.1.202   # k8s-worker-01
ssh -i ~/.ssh/k8s_ansible ubuntu@192.168.1.203   # k8s-worker-02
```

Workers do not have kubectl configured — use the control plane or your local
kubeconfig for all cluster commands.

---

## Routine operations

### Check cluster health

```bash
export KUBECONFIG=kubeconfig/homelab.yaml

# Are all nodes Ready?
kubectl get nodes

# Any Pods not Running?
kubectl get pods -A | grep -v Running | grep -v Completed

# Control-plane component status
kubectl get componentstatuses
```

Expected healthy output from `get nodes`:

```
NAME            STATUS   ROLES           AGE   VERSION
k8s-cp-01       Ready    control-plane   Nd    v1.31.4
k8s-worker-01   Ready    <none>          Nd    v1.31.4
k8s-worker-02   Ready    <none>          Nd    v1.31.4
```

---

### Trigger a Terraform plan (verify no drift)

1. Create a branch, make any trivial change to a `.tf` file (or just a comment).
2. Open a PR against `main`.
3. The `terraform-plan.yml` workflow runs automatically.
4. Review the plan in the Actions tab — it should show `No changes` if
   infrastructure matches state.
5. Close the PR without merging.

---

### Upgrade Kubernetes version

1. Check Kubespray's release page for the compatible `kube_version`:
   https://github.com/kubernetes-sigs/kubespray/releases

2. Update in `ansible/inventory/group_vars/all/kubespray.yml`:
   ```yaml
   kube_version: v1.32.0  # new version
   ```

3. Update the Kubespray branch in `.forgejo/workflows/ansible-deploy.yml`:
   ```yaml
   git clone --branch v2.27.0 --depth 1 \  # new Kubespray tag
   ```

4. Trigger the **Ansible — Deploy K8s Cluster** workflow with
   `kubespray_tags: upgrade` to run only the upgrade tasks.

> **Warning:** K8s upgrades are one minor version at a time (1.31 → 1.32,
> not 1.31 → 1.33). Check Kubespray docs for multi-version upgrade paths.

---

### Destroy and rebuild the cluster from scratch

Use this when the cluster is irrecoverably broken, when you want to test the
full pipeline end-to-end, or when you simply want a clean slate to learn from.

**Total time from destroy to healthy cluster: ~60–70 minutes.**

---

#### Before you destroy — pre-flight checks

Destroy is irreversible. The VMs and the template are deleted from Proxmox.
The Terraform state in RustFS is updated to reflect this — it does not delete
the state file itself. Run these checks first:

```bash
# Confirm what Terraform currently tracks
# Run on the runner LXC inside the Terraform working directory
terraform state list
```

Expected output before a destroy:
```
module.k8s_cp_01.data.proxmox_virtual_environment_vms.template
module.k8s_cp_01.proxmox_virtual_environment_vm.vm
module.k8s_worker_01.data.proxmox_virtual_environment_vms.template
module.k8s_worker_01.proxmox_virtual_environment_vm.vm
module.k8s_worker_02.data.proxmox_virtual_environment_vms.template
module.k8s_worker_02.proxmox_virtual_environment_vm.vm
module.ubuntu_template.proxmox_virtual_environment_download_file.ubuntu_cloud_image
module.ubuntu_template.proxmox_virtual_environment_vm.template
```

Eight resources — four VMs (3 cluster + 1 template) and four supporting data
sources. If this list is empty, Terraform already considers nothing to exist —
a destroy run will be a no-op (see the `Resources: 0 destroyed` output below).

---

#### Step 1 — Trigger the destroy

Navigate to Forgejo → Actions → **Terraform — Apply** → **Run workflow**.

Change the `terraform_action` input from `apply` to `destroy`. Leave everything
else as default. Click **Run workflow**.

**What the workflow does during destroy:**

The workflow runs `terraform destroy -auto-approve`. This:
1. Reads current state from RustFS
2. Calls the Proxmox API to delete VMs 201, 202, 203 and template 9000
3. Calls the Proxmox API to remove the downloaded cloud image from storage
4. Updates the RustFS state file to record that nothing exists

---

#### What a successful destroy looks like

```
Terraform destroy
Destroy complete! Resources: 4 destroyed.
```

If VMs were already deleted outside Terraform (e.g. you deleted them manually
in the Proxmox UI), you will see:

```
Terraform destroy
No changes. No objects need to be destroyed.
Either you have not created any objects yet or the existing objects
were already deleted outside of Terraform.
Destroy complete! Resources: 0 destroyed.
```

`Resources: 0 destroyed` is not an error — it means Terraform looked at the
current state, found the objects already gone, and confirmed there is nothing
to do. This is exactly the output produced when you ran destroy after the VMs
were removed from Proxmox by another means.

The deprecation warnings that follow are harmless and unrelated to the destroy:

```
Warning: Deprecated
  with module.ubuntu_template.proxmox_virtual_environment_download_file...
  Use "proxmox_download_file" instead. This resource / data source will be
  removed in v1.0.
```

These appear because the provider is warning about a renamed resource — they
will be resolved when the provider is upgraded to v1.0. They do not affect
destroy behaviour.

---

#### Step 2 — Confirm in Proxmox UI

Open Proxmox → your node. VMs 201, 202, 203, and 9000 should be gone.
If any remain, they were created outside Terraform and are not in state — delete
them manually via Proxmox UI before proceeding to the rebuild.

---

#### Step 3 — Rebuild

Trigger **Terraform — Apply** with `terraform_action = apply`.

The workflow will:
1. Download the Ubuntu 24.04 cloud image again
2. Create template VM 9000
3. Clone it three times into VMs 201, 202, 203
4. Run cloud-init to set static IPs and inject the Ansible SSH key

Wait for the apply to complete (`Resources: 5 added`). Confirm all three VMs
are visible and running in the Proxmox UI before continuing.

---

#### Step 4 — Reinstall Kubernetes

Trigger **Ansible — Deploy K8s Cluster** with both inputs blank (full run).

This takes 45–60 minutes. See Chapter 07 for the progress milestones.

---

#### Step 5 — Refresh your kubeconfig

After the deploy completes, the new cluster has new certificates. Your old
`~/.kube/homelab.yaml` will not work. Download the fresh `kubeconfig-homelab`
artifact from the new deploy run and overwrite the file:

```bash
# On LXC-Rocky10
mv ~/.kube/homelab.yaml ~/.kube/homelab.yaml.old  # keep as backup temporarily
# paste new file content or scp from workstation
chmod 600 ~/.kube/homelab.yaml
kubectl get nodes  # should show all three Ready
rm ~/.kube/homelab.yaml.old
```

---

#### After a destroy — state file behaviour

`terraform destroy` updates the state file in RustFS but does not delete it.
After a successful destroy, the state file exists but contains no resources.
The next `terraform apply` starts from this empty state and creates everything
fresh. You do not need to touch the RustFS bucket or the state file manually.

---

## Incident response

### A workflow is stuck / never picked up

**Symptom:** A workflow sits in "Waiting" forever.

**Check:** Is the runner online?

```bash
# On the Proxmox host, check LXC status
pct status <runner-lxc-id>

# Inside the runner LXC
systemctl status forgejo-runner
journalctl -u forgejo-runner -n 50
```

**Fix if runner is stopped:**
```bash
systemctl start forgejo-runner
```

**Fix if runner is online but not picking up jobs:** Verify the label in
`runner-config.yml` is `proxmox-infra:host` (with `:host` suffix). See
[Chapter 10 — Troubleshooting Labs](10-troubleshooting-labs.md) for the full diagnosis.

---

### Terraform apply fails mid-run

**Symptom:** The apply workflow errors partway through, leaving some VMs
created and others not.

**Step 1:** Check Proxmox UI for partially-created VMs (`qm list`).

**Step 2:** Check Terraform state to see what was recorded:
```bash
cd terraform/envs/homelab
terraform state list
```

**Step 3:** For each orphaned/broken VM on the Proxmox side but not in state:
```bash
# On Proxmox host
qm stop <vmid> --skiplock 2>/dev/null || true
qm destroy <vmid> --destroy-unreferenced-disks 1 --purge 1
```

**Step 4:** For each VM in state but not on Proxmox:
```bash
terraform state rm <resource.address>
```

**Step 5:** Re-trigger the apply. See [Chapter 10 — Troubleshooting Labs](10-troubleshooting-labs.md) for
specific recovery examples.

---

### A node goes NotReady

**Symptom:** `kubectl get nodes` shows one node as `NotReady`.

**Diagnose:**
```bash
# Get events on the node
kubectl describe node <node-name>

# SSH to the node and check kubelet
ssh -i ~/.ssh/k8s_ansible ubuntu@192.168.1.20X
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 100
```

**Common causes:**

- **kubelet stopped:** `sudo systemctl restart kubelet`
- **containerd stopped:** `sudo systemctl restart containerd`
- **Disk full:** `df -h` — clean up if > 90% used
- **VM rebooted and swap came back:**
  ```bash
  sudo swapoff -a  # immediate
  # verify /etc/fstab has swap commented out (should be from pre-k8s.yml)
  ```

---

### Can't connect to cluster (kubeconfig error)

**Symptom:** `kubectl` errors with connection refused or certificate issues.

**Check 1:** Is the control plane VM running?
```bash
# In Proxmox UI or:
ping 192.168.1.201
ssh -i ~/.ssh/k8s_ansible ubuntu@192.168.1.201 systemctl status kube-apiserver
```

**Check 2:** Is your kubeconfig pointing at the right IP?
```bash
grep server kubeconfig/homelab.yaml
# Should be: server: https://192.168.1.201:6443
```

If not, re-run the `post-k8s.yml` playbook or manually patch it:
```bash
sed -i 's|server: https://.*:6443|server: https://192.168.1.201:6443|' \
  kubeconfig/homelab.yaml
```

**Check 3:** Is the certificate still valid?
```bash
kubectl --kubeconfig kubeconfig/homelab.yaml cluster-info
# If cert expired: rebuild the cluster or rotate certs with kubeadm
```

---

### RustFS is unreachable (Terraform state backend error)

**Symptom:** `terraform init` fails with an S3 connection error.

**Check:** Is TrueNAS and the RustFS pod up?
```bash
curl http://192.168.1.50:30293/terraform-state/
# Should return an XML-like response (ListBucketResult or AccessDenied)
```

If `curl` times out: TrueNAS or the RustFS app is down. Fix TrueNAS first.

If `curl` returns XML: credentials may be wrong. Re-check `RUSTFS_ACCESS_KEY`
and `RUSTFS_SECRET_KEY` in Forgejo Secrets.

---

## Maintenance windows

### VM disk space check

```bash
# From runner or local machine:
ansible all -i ansible/inventory/generated/hosts.yaml \
  --private-key ~/.ssh/k8s_ansible \
  -m shell -a "df -h / /var"
```

Alert threshold: 80% used. At 90%, Kubernetes starts evicting Pods.

### Certificate rotation (annual)

Kubespray-installed clusters have certificates that expire after 1 year by
default. `kubeadm` can renew them without cluster downtime:

```bash
ssh -i ~/.ssh/k8s_ansible ubuntu@192.168.1.201
sudo kubeadm certs check-expiration
sudo kubeadm certs renew all
sudo systemctl restart kube-apiserver kube-controller-manager kube-scheduler
```

After rotation, fetch a fresh kubeconfig (the old one uses the old cert):
```bash
# Re-run post-k8s.yml, or manually:
sudo cat /etc/kubernetes/admin.conf > /tmp/admin.conf
# scp to local, replace kubeconfig/homelab.yaml
```

### Proxmox host updates

Proxmox updates don't affect running VMs but may require a host reboot. Schedule
during low-traffic periods. After reboot, VMs marked "Start at boot" in Proxmox
will restart automatically — check that `Start at boot` is enabled for VMs
201, 202, 203 in the Proxmox UI (Options → Start at boot → Yes).

---

## Useful one-liners

```bash
# Watch all pods until they're all Running
kubectl get pods -A -w | grep -v Running

# Get logs from a specific pod
kubectl logs -n <namespace> <pod-name> --tail=100 -f

# Run a debug shell on a node
kubectl debug node/k8s-worker-01 -it --image=busybox

# Check resource usage
kubectl top nodes
kubectl top pods -A

# Drain a node for maintenance (cordon + evict pods)
kubectl drain k8s-worker-01 --ignore-daemonsets --delete-emptydir-data
# After maintenance:
kubectl uncordon k8s-worker-01

# Force-delete a stuck pod
kubectl delete pod <name> -n <ns> --grace-period=0 --force
```

---

*Previous: [Chapter 08 — kubectl Access](08-kubectl-access.md) · Next: [Chapter 10 — Troubleshooting Labs](10-troubleshooting-labs.md)*
