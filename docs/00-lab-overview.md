# Lab Overview — k8s-infra Homelab

Welcome to the **k8s-infra** learning lab. This book walks you through building
a real, fully-automated Kubernetes cluster on Proxmox from scratch — no shortcuts,
no pre-built images, no hand-waving. Every step is explained, every command is
shown, and every decision has a reason.

By the end you will have:

- A three-node Kubernetes cluster running on Proxmox VMs
- Terraform managing the VMs, Ansible deploying Kubernetes, Forgejo orchestrating both
- A complete GitOps monorepo you understand end-to-end
- The vocabulary and mental models to maintain and extend it yourself

---

## Who this lab is for

Someone who:

- Is comfortable at a Linux terminal (you know `cd`, `cat`, `ssh`, `sudo`)
- Has not worked with Kubernetes, Terraform, or Ansible before (or has dabbled but not built from scratch)
- Is running their own homelab hardware (or similar)
- Wants to understand *why*, not just *how*

If you have done parts of this before, jump to the chapter that covers your gap.
Each chapter stands alone.

---

## What's in the repo

```
k8s-infra/
├── .forgejo/workflows/     ← CI/CD pipeline definitions (YAML)
├── terraform/              ← VM provisioning code (HCL — HashiCorp Configuration Language)
│   ├── envs/homelab/       ← environment: what to build
│   └── modules/            ← reusable VM building blocks
├── ansible/                ← Kubernetes installation (YAML playbooks)
│   ├── inventory/          ← host lists and config variables
│   ├── playbooks/          ← pre-k8s, post-k8s plays
│   └── scripts/            ← inventory generator (Python)
├── tests/                  ← unit tests for the inventory generator
└── docs/                   ← this book, plus reference docs
```

---

## Chapter map

**Chapters 01–08 are guided labs.** Follow them in order the first time through.
Each has: Goal · You will learn · Prerequisites · Where to run commands · Steps ·
Expected output · Checkpoint questions · Common mistakes.

| Chapter | What you build | Time |
|---|---|---|
| [01 — Concepts & Architecture](01-concepts.md) | Mental model | 30 min read |
| [02 — Lab Environment](02-lab-environment.md) | Overview of hardware and services | 15 min read |
| [03 — Proxmox Prep](03-proxmox-prep.md) | API user, token, SSH keys, Forgejo secrets | 45 min |
| [04 — RustFS State Backend](04-rustfs-state-backend.md) | S3 bucket for Terraform state | 20 min |
| [05 — Forgejo Runner](05-forgejo-runner.md) | LXC CI runner, registered and running | 45 min |
| [06 — Terraform VMs](06-terraform-vms.md) | Three K8s VMs provisioned | 60 min |
| [07 — Ansible & Kubespray](07-ansible-kubespray.md) | Kubernetes installed and running | 90 min |
| [08 — kubectl Access](08-kubectl-access.md) | kubectl working from admin host | 20 min |

**Chapters 09–12 are reference chapters.** Use them when you need them —
not sequentially. They may include checkpoint questions, but they are not
part of the required guided-lab path.

| Chapter | Contents |
|---|---|
| [09 — Operations Runbook](09-operations-runbook.md) | Day-to-day procedures, VM start/stop, upgrade steps |
| [10 — Troubleshooting Labs](10-troubleshooting-labs.md) | Diagnosed failures with root cause and fix |
| [11 — Security & Key Rotation](11-security-key-rotation.md) | Credential management, rotation procedures |
| [12 — Upgrades & Next Steps](12-upgrades-next-steps.md) | Kubernetes upgrade path, next capability options |

**Appendices:**

| File | Contents |
|---|---|
| [appendix/adr.md](appendix/adr.md) | Architecture Decision Records — why things are the way they are |
| [appendix/glossary.md](appendix/glossary.md) | Definitions of every term used in the lab |
| [appendix/failure-labs.md](appendix/failure-labs.md) | Intentional break/fix exercises |

---

## Prerequisites before you start

Before Chapter 03 you need:

- **Proxmox VE** installed on your server and accessible at its web UI
- **TrueNAS Scale** (or similar NAS) running Forgejo, Forgejo Runner, and RustFS
- **Git client** installed on your workstation (GitHub Desktop, CLI, anything)
- **SSH client** on your workstation

You do *not* need Kubernetes, Terraform, or Ansible installed locally.
Everything that touches the infrastructure runs inside the Forgejo runner LXC.

---

## How to use this lab

**First time through:** read Chapter 01 before touching anything. Then follow
Chapters 03–08 in order. Each chapter ends with checkpoint questions and a
common mistakes table — work through them before moving on.

**Already deployed:** jump to the relevant reference chapter (09–12) or
appendix.

**Something broke:** start with [Chapter 10 — Troubleshooting](10-troubleshooting-labs.md).

**Something sounds weird:** the [Glossary](appendix/glossary.md) and
[ADR](appendix/adr.md) exist for exactly this.

---

## Current state of this cluster

| Component | Version / Value |
|---|---|
| Kubernetes | v1.31.4 via Kubespray v2.26.0 |
| Container runtime | containerd |
| CNI | Calico, IPIP Always |
| Proxmox | VMs 201 (cp-01), 202 (worker-01), 203 (worker-02) |
| OS | Ubuntu 24.04 cloud-init |
| CI/CD | Forgejo Actions, runner label `proxmox-infra:host` |
| State backend | RustFS on TrueNAS (`terraform-state` bucket) |

All three workflows (`terraform-plan`, `terraform-apply`, `ansible-deploy`) are
working. The cluster is live. See Chapter 09 for day-to-day operations.
