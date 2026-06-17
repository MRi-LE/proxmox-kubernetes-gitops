# Chapter 07 — Ansible & Kubespray

**Goal:** Kubernetes v1.31.4 installed on all three VMs, all nodes Ready,
all system pods Running, and a kubeconfig artifact available to download.

**You will learn:** How the three Ansible playbooks work in sequence, what
Kubespray does (and what it doesn't), how to read `ansible-deploy` workflow
logs, and what a healthy cluster looks like on first boot.

**Prerequisites:** [Chapter 06 — Terraform VMs](06-terraform-vms.md). All three
VMs must be running and reachable by SSH before starting this chapter.

**Where to run commands:**

| Step | Run on | How |
|---|---|---|
| Trigger `ansible-deploy` | Forgejo web UI | Actions → workflow_dispatch |
| Watch logs | Forgejo web UI | Actions tab → ansible-deploy run |
| Download kubeconfig | Forgejo web UI | Artifacts section of the run |
| Verify with kubectl | LXC-Rocky10 | SSH in, run kubectl |

---

## What the workflow does, step by step

The `ansible-deploy.yml` workflow runs the following sequence every time it's triggered:

```
1. Check out the repo
2. Write ANSIBLE_SSH_PRIVATE_KEY to ~/.ssh/k8s_ansible  (from Forgejo secret)
3. Clone Kubespray v2.26.0 into ansible/kubespray/       (runtime, not committed)
4. Install Python dependencies into a venv               (Ansible + collections)
5. Re-run terraform init + output to get current IPs
6. Run generate_inventory.py → ansible/inventory/generated/hosts.yaml
7. Run pre-k8s.yml    (wait for SSH, wait for cloud-init, install packages)
8. Run kubespray/cluster.yml  (full Kubernetes install, ~30–40 min)
9. Run post-k8s.yml   (fetch kubeconfig from control plane, patch server URL)
10. Upload kubeconfig/homelab.yaml as artifact
11. Always: delete ~/.ssh/k8s_ansible and generated inventory
```

---

## The three playbooks

### `pre-k8s.yml` — all three nodes

Prepares the VMs before Kubespray runs. Key tasks:

- Waits for SSH to be available (cloud-init can take 60–90 seconds after VM boot)
- Runs `cloud-init status --wait` to confirm first-boot setup is complete
- Installs required packages (`python3`, `python3-pip`, `curl`, `ca-certificates`, `gnupg`, `lsb-release` — the base toolchain Kubespray expects on each node)
- Disables swap (Kubernetes requires it off)
- Sets required kernel modules and sysctl values

**Why it exists:** Kubespray assumes nodes are already prepared. Without `pre-k8s.yml`,
Kubespray can fail on fresh VMs that haven't finished booting.

---

### `cluster.yml` (Kubespray) — all three nodes

This is the Kubespray playbook that does the actual Kubernetes installation.
It takes 30–45 minutes on first run. It:

1. Installs containerd on all nodes
2. Installs kubeadm, kubelet, kubectl
3. Bootstraps etcd (co-located with control plane on cp-01)
4. Runs `kubeadm init` on cp-01
5. Installs Calico CNI
6. Runs `kubeadm join` on worker-01 and worker-02
7. Installs Helm, Metrics Server, and other enabled addons

**Key configuration** (in `ansible/inventory/group_vars/all/kubespray.yml`):

| Setting | Value | Why |
|---|---|---|
| `kube_version` | `v1.31.4` | Pinned for reproducibility |
| `kube_network_plugin` | `calico` | Battle-tested L3 CNI |
| `calico_ipip_mode` | `Always` | Required for same L2 segment; avoids ARP issues |
| `container_manager` | `containerd` | Standard CRI since K8s 1.24 |
| `etcd_deployment_type` | `kubeadm` | Co-located with control plane |
| `helm_enabled` | `true` | Needed for most real workloads |
| `metrics_server_enabled` | `true` | Enables `kubectl top nodes` |

---

### `post-k8s.yml` — control plane only

Retrieves the kubeconfig and makes it available for download. Key tasks:

1. Copies `/etc/kubernetes/admin.conf` off the control plane node
2. Fetches it to the runner (`delegate_to: localhost`)
3. Patches the server URL from `127.0.0.1:6443` to `192.168.1.201:6443`
4. Uploads `kubeconfig/homelab.yaml` as a Forgejo artifact

**`become: false` at play level** — this play runs on the runner LXC for the
`delegate_to: localhost` tasks. The runner's `forgejo-runner` user has no
passwordless sudo, so `become` must be disabled at play level. Individual tasks
that need root on the remote node set `become: true` explicitly.

---

## Triggering the workflow

Navigate to Forgejo → Actions → **Ansible — Deploy K8s Cluster** → **Run workflow**.

Two optional inputs:

| Input | Default | When to use |
|---|---|---|
| `kubespray_tags` | (blank — full run) | `apps` for addon-only run; `upgrade` for version upgrade |
| `skip_preflight` | `false` | Set to `true` to skip `pre-k8s.yml` entirely — use only if VMs were already prepared by a previous run and you want to re-run Kubespray faster |

For a fresh cluster install, leave both blank.

---

## Successful run: what good looks like

The workflow takes 45–60 minutes total on a fresh install. A healthy run has
four visible stages in the Forgejo Actions log.

### Stage 1 — Terraform output extracted

The workflow initialises Terraform against the RustFS backend, reads current
state, and writes the generated output. The inventory generator then produces
the Kubespray host file:

```
Inventory written → ansible/inventory/generated/hosts.yaml
```

If this step fails, no Ansible step will run. Check the RustFS backend is
reachable and the Forgejo secrets are correct.

### Stage 2 — pre-k8s.yml completes with failed=0

```
PLAY RECAP
k8s-cp-01      : ok=X  changed=X  unreachable=0  failed=0  ...
k8s-worker-01  : ok=X  changed=X  unreachable=0  failed=0  ...
k8s-worker-02  : ok=X  changed=X  unreachable=0  failed=0  ...
```

This confirms SSH is up, cloud-init has finished, hostnames are set, swap is
off, kernel modules are loaded, and sysctl values are correct. If any node
shows `failed=1` here, do not proceed — fix the failing node first.

### Stage 3 — Kubespray cluster.yml completes with failed=0

This is the long step (30–45 min). The final recap should show:

```
PLAY RECAP
k8s-cp-01      : ok=X  changed=X  unreachable=0  failed=0  ...
k8s-worker-01  : ok=X  changed=X  unreachable=0  failed=0  ...
k8s-worker-02  : ok=X  changed=X  unreachable=0  failed=0  ...
```

The exact `ok=` and `changed=` counts vary between runs and Kubespray versions.
`failed=0` and `unreachable=0` on all three nodes is the signal that matters.

**What to watch for during the run — milestones by time:**

Kubespray logs hundreds of tasks. You don't need to read every line, but these
landmarks tell you the run is progressing normally. If the log is silent for
more than 5 minutes, suspect a network issue or a task waiting for a timeout.

| ~Time into run | What you should see in the log | If you don't see it |
|---|---|---|
| 0–5 min | `TASK [bootstrap-os : ...` — OS detection and package setup on all nodes | SSH may still be refused — check pre-k8s ran cleanly |
| 5–10 min | `TASK [download : Download ...` — container images being pulled | Likely a Docker Hub rate limit or DNS failure on VMs |
| 10–20 min | `TASK [etcd : ...` — etcd cluster bootstrapping on cp-01 | A hung etcd task often means the cp-01 VM ran out of RAM |
| 20–30 min | `TASK [kubernetes/control-plane : ...` — kubeadm init on cp-01, then Calico CNI | If kubeadm init fails, check VM disk space (`df -h` on cp-01) |
| 30–40 min | `TASK [kubernetes/node : ...` — workers joining the cluster | A timeout here usually means the API server on cp-01 is not reachable from the worker |
| 40–45 min | `TASK [kubernetes-apps/...` — Helm, Metrics Server, addon installation | This phase is safe to be slower — addon images can be large |
| Final | `PLAY RECAP` with `failed=0` on all three nodes | If missing, the run terminated early — scroll up for `fatal:` |

> **If a task is silent for more than 5 minutes:** open a second terminal,
> SSH into the affected node, and run `sudo journalctl -u containerd -n 30`
> or `sudo crictl ps` to see if container activity is happening. Sometimes
> a large image pull is in progress but Ansible is waiting silently.

### Stage 4 — post-k8s.yml fetches the kubeconfig

The workflow uploads `kubeconfig-homelab` as a Forgejo artifact. After
downloading it and placing it at `~/.kube/homelab.yaml` on LXC-Rocky10,
`kubectl get nodes` should show:

```
NAME            STATUS   ROLES           AGE    VERSION
k8s-cp-01       Ready    control-plane   <age>  v1.31.4
k8s-worker-01   Ready    <none>          <age>  v1.31.4
k8s-worker-02   Ready    <none>          <age>  v1.31.4
```

All three `Ready` with the correct version. See Chapter 08 for the full kubectl
verification steps.

---

## Known harmless Kubespray warnings

Kubespray prints several warnings during a successful run. They are noisy but
not fatal. As long as the final `PLAY RECAP` shows `failed=0` and the nodes
become `Ready`, these can be ignored.

| Warning text | Meaning | Action |
|---|---|---|
| `found a duplicate dict key (paths). Using last defined value only.` | Upstream Kubespray YAML contains the same key twice in one task file. Ansible keeps the last value. | Ignore. |
| `Conditional result ... was of type 'str' / 'list' / 'int'` | Some Kubespray conditionals use older Ansible behaviour. Current Ansible interprets them but warns that future versions may reject them. | Ignore while pinned to Ansible 2.16.x. Re-check when upgrading Kubespray. |
| `Could not match supplied host pattern, ignoring: kube-master` (and `kube-node`, `k8s-cluster`, `calico-rr`, `no-floating`, `bastion`) | Kubespray includes compatibility plays for optional or legacy inventory groups. This lab does not define those groups, so Ansible skips them. | Ignore. The groups that matter are `kube_control_plane`, `kube_node`, and `etcd`. |
| `raw module does not support the environment keyword` | Kubespray uses Ansible's `raw` module during bootstrap. The `raw` module cannot accept `environment:`. The task still runs. | Ignore if the following bootstrap tasks show `ok`. |

**Rule:** treat a warning as harmless only if the run continues and the final
recap shows `failed=0`. If you see `fatal`, `FAILED`, `unreachable=1`, or the
run ends without a final `PLAY RECAP`, stop ignoring and start diagnosing.

---

## Partial re-runs with tags

Once the cluster is installed, you don't always need a full Kubespray run.
Kubespray supports tags to run only specific phases:

| `kubespray_tags` value | What runs |
|---|---|
| (blank) | Full cluster install or full upgrade |
| `apps` | Only addons (Helm charts, Metrics Server, etc.) |
| `upgrade` | Kubernetes version upgrade only |
| `network` | CNI reconfiguration only |

Example: to enable ingress-nginx without a full reinstall:

1. Set `ingress_nginx_enabled: true` in `kubespray.yml`
2. Trigger the workflow with `kubespray_tags: apps`

---

## Checkpoint questions

1. What does `pre-k8s.yml` do and why must it run before Kubespray?
2. The Kubespray run shows `failed=1` on `k8s-worker-02`. What do you do first?
3. Why is `become: false` set at play level in `post-k8s.yml`?
4. After a cluster rebuild, your old kubeconfig stops working. Why, and what do you do?
5. What is the purpose of `kubespray_tags`? When would you use `apps` instead of a full run?

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Ansible deploy triggered before VMs are fully up | SSH timeout in `pre-k8s.yml` | Wait for all three VMs to show Running in Proxmox, then re-trigger |
| `kube_version` updated without updating Kubespray tag | Version mismatch error from kubeadm | Always update both `kube_version` and the `git clone --branch` tag together |
| Old kubeconfig used after cluster rebuild | `certificate signed by unknown authority` error | Download fresh artifact from the new deploy run |
| `kubespray/` directory not cleaned before re-run | Stale Kubespray files from previous run | Workflow already runs `rm -rf ansible/kubespray` — if running manually, do this first |
| Kubespray run with `upgrade` tag without incrementing one minor version | Node may break | K8s upgrades are one minor version at a time: 1.31 → 1.32 only |

---

*Previous: [Chapter 06 — Terraform VMs](06-terraform-vms.md) · Next: [Chapter 08 — kubectl Access](08-kubectl-access.md)*
