# Chapter 02 — Lab Environment

**Goal:** Know exactly what hardware and services exist, where they live on the
network, and which machine runs each command throughout the lab.

**You will learn:** The physical and logical layout of the homelab, why each
service lives where it does, and how to orient yourself before making any changes.

**Prerequisites:** [Chapter 01 — Concepts & Architecture](01-concepts.md)

**Where to run commands:** Nowhere yet — this chapter is orientation only.

---

## Physical hardware

| Machine | What runs on it | LAN IP |
|---|---|---|
| **Proxmox host** | Proxmox VE hypervisor; all VMs and LXCs | `192.168.1.100` |
| **TrueNAS Scale** | Forgejo, Forgejo Runner (non-infra), RustFS | `192.168.1.50` |
| **Your workstation** | Git client, browser, occasional kubectl | DHCP |

Everything is LAN-only. There is no internet-facing component.

---

## Logical services

```
192.168.1.100  — Proxmox host
  └── VMs:
        201  k8s-cp-01       (2 vCPU, 4 GB RAM, 30 GB)  ← K8s control plane
        202  k8s-worker-01   (2 vCPU, 6 GB RAM, 40 GB)  ← K8s worker
        203  k8s-worker-02   (2 vCPU, 6 GB RAM, 40 GB)  ← K8s worker
        9000 ubuntu-24.04-cloud (template — not running) ← VM clone source
  └── LXCs:
        forgejo-runner-infra  ← CI runner (proxmox-infra:host label)
        LXC-Rocky10           ← kubectl admin host (Rocky Linux 10)

192.168.1.50  — TrueNAS Scale
  └── Forgejo           http(s)://<truenas-host>/    ← Git forge + CI/CD
  └── RustFS            http://192.168.1.50:30293 ← Terraform state (S3)
  └── RustFS console    http://192.168.1.50:30292 ← Web UI for RustFS
```

---

## Where each command runs

Throughout the lab, commands run in different places. This table is the master
reference — each later chapter repeats the relevant row.

| Task | Run on | User |
|---|---|---|
| Create Proxmox user / token | Proxmox host shell | `root` |
| Generate SSH keypairs | Your workstation or runner LXC | any |
| Authorise `k8s_proxmox` key | Proxmox host | `root` |
| Create RustFS bucket | TrueNAS console or any machine with `mc` | any |
| Set up Forgejo secrets / variables | Forgejo web UI | repo admin |
| Runner LXC setup | Runner LXC (`forgejo-runner-infra`) | `root`, then `forgejo-runner` |
| Trigger CI workflows | Forgejo web UI | any |
| Day-to-day kubectl | LXC-Rocky10 | `root` |
| SSH to K8s VMs (debugging) | Your workstation or LXC-Rocky10 | `ubuntu` via `k8s_ansible` key |
| SSH to Proxmox host (debugging) | Your workstation | `root` via `k8s_proxmox` key |

---

## Network layout

All VMs use static IPs assigned via cloud-init. The default gateway for every
VM is the LAN router at `192.168.1.1`. DNS servers are `1.1.1.1` and `8.8.8.8`.

```
LAN: 192.168.1.0/24
Gateway: 192.168.1.1

.50   TrueNAS (Forgejo, RustFS)
.100  Proxmox host
.201  k8s-cp-01       — Kubernetes API server (port 6443)
.202  k8s-worker-01
.203  k8s-worker-02
.210  forgejo-runner-infra LXC  (example — adjust to your actual IP)
.XXX  LXC-Rocky10               (adjust to your actual IP)
```

---

## Forgejo secrets and variables

These must be configured before any workflow will succeed. They are set once in
Forgejo → Repository → Settings and then consumed by every workflow run.

**Secrets** (encrypted, never visible in logs):

| Secret | What it is |
|---|---|
| `PROXMOX_VE_ENDPOINT` | `https://<your-proxmox-ip>:8006` |
| `PROXMOX_VE_API_TOKEN` | `terraform@pam!ci=<uuid>` |
| `PROXMOX_SSH_PRIVATE_KEY` | Contents of `~/.ssh/k8s_proxmox` |
| `ANSIBLE_SSH_PRIVATE_KEY` | Contents of `~/.ssh/k8s_ansible` |
| `ANSIBLE_SSH_PUBLIC_KEY` | Contents of `~/.ssh/k8s_ansible.pub` |
| `RUSTFS_ACCESS_KEY` | RustFS access key |
| `RUSTFS_SECRET_KEY` | RustFS secret key |
| `RUSTFS_ENDPOINT` | RustFS S3 endpoint, e.g. `http://<your-truenas-ip>:30293`. Used by `terraform init -backend-config` — cannot be a Terraform variable because the backend block is evaluated before variables are resolved. |

**Variables** (plain text, visible in logs — non-sensitive):

| Variable | Value |
|---|---|
| `TF_VAR_PROXMOX_NODE` | Your Proxmox node name (check Proxmox UI) |
| `TF_VAR_NETWORK_GATEWAY` | Your LAN gateway IP |
| `TF_VAR_NETWORK_BRIDGE` | Proxmox bridge interface (e.g. `vmbr0`) |
| `TF_VAR_CP01_IP` | A free static IP on your LAN for the control-plane VM |
| `TF_VAR_WORKER01_IP` | A free static IP on your LAN for worker-01 |
| `TF_VAR_WORKER02_IP` | A free static IP on your LAN for worker-02 |
| `TF_VAR_DISK_DATASTORE` | `local-lvm` |
| `TF_VAR_IMAGE_DATASTORE` | `local` |
| `TF_VAR_PROXMOX_TLS_INSECURE` | `true` |

> **All IP variables are required.** There are no defaults — each is specific
> to your LAN. Choose IPs that are outside your DHCP range and verify they are
> free before setting them.

---

## Three workflows, one pipeline

| Workflow file | Trigger | What it does |
|---|---|---|
| `terraform-plan.yml` | Auto on every PR | Shows what Terraform *would* change — read-only, safe |
| `terraform-apply.yml` | Manual `workflow_dispatch` | Actually creates or destroys VMs |
| `ansible-deploy.yml` | Manual `workflow_dispatch` | Installs/upgrades Kubernetes |
| `validate.yml` | Auto on every PR | Lints Terraform, Python, YAML; runs pytest |

Apply and deploy are always manual — no accidental infrastructure changes.

---

## Checkpoint questions

1. Which IP address is the Kubernetes API server? Which port?
2. What is the difference between a Forgejo Secret and a Forgejo Variable?
3. Name two tasks that run on the Proxmox host directly, not via CI.
4. Why are the three cluster VMs given static IPs rather than DHCP?
5. Which workflow is safe to trigger on any PR without risk to the cluster?

---

*Previous: [Chapter 01 — Concepts](01-concepts.md) · Next: [Chapter 03 — Proxmox Prep](03-proxmox-prep.md)*
