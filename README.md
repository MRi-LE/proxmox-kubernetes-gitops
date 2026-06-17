# proxmox-kubernetes-gitops

> 📝 **Background & motivation:** [Building a GitOps-Style Kubernetes Homelab on Proxmox](https://michaelrichter.online/building-a-gitops-style-kubernetes-homelab-on-proxmox/)

---

## Why this project exists

Preparing for a new role as a DevOps Engineer, I was spending hours on video
training — Udemy, LinkedIn Learning, YouTube. Good material exists out there,
but it can be slow-paced and not always hands-on enough. So I built something
real instead.

The goal was a Kubernetes homelab that can be **created, reviewed, destroyed,
rebuilt, and extended over time** — not a one-time manual setup, but a clean,
documented foundation I can confidently revisit months later when something
breaks at the least convenient moment.

The core idea is simple:

- **Git** stores the desired state
- **Forgejo** runs the workflows
- **Terraform** creates the virtual machines
- **Ansible + Kubespray** installs Kubernetes
- **RustFS** stores the Terraform state
- **Proxmox** runs the cluster

That separation — infrastructure provisioning strictly separated from
Kubernetes installation, both orchestrated by CI but never applied
automatically — is what turns this from a one-time install into something
closer to real infrastructure-as-code.

The most useful lessons from building this weren't only about Kubernetes itself.
They were about the integration points *around* Kubernetes: runner reachability,
Proxmox API permissions, state surviving outside the runner, SSH keys separated
by purpose, inventory matching Terraform output, and workflow inputs staying
predictable. Those details are where homelab automation usually fails — and
they're documented here next to the code, not hidden away.

**This project is not a production platform.** It is a reproducible, documented
learning environment. The value is that the path to a running cluster is now
visible, version-controlled, and repeatable.

---

GitOps monorepo for deploying a Kubernetes cluster on Proxmox.

**Stack:** Terraform (VM provisioning) → Ansible + Kubespray (K8s install) → Forgejo CI/CD

**Status:** Fully deployed. Kubernetes v1.31.4 running on 3 VMs (1 control plane, 2 workers).

**Documentation:** Start with [docs/00-lab-overview.md](docs/00-lab-overview.md) — a sequential
junior-developer training book covering every step from a fresh Proxmox host to a running cluster.

## Repository layout

```
k8s-infra/
├── .forgejo/workflows/
│   ├── terraform-plan.yml     # auto: runs on every PR touching terraform/
│   ├── terraform-apply.yml    # manual: provisions VMs (workflow_dispatch)
│   ├── ansible-deploy.yml     # manual: installs K8s (workflow_dispatch)
│   └── validate.yml           # auto: fmt, validate, lint, pytest on every PR
├── terraform/
│   ├── envs/homelab/          # environment config, backend, variables
│   │   ├── backend.tf         # RustFS S3 state backend
│   │   ├── main.tf            # provider + module wiring
│   │   ├── variables.tf       # all input variables
│   │   ├── outputs.tf         # vm_ips, control_planes, workers — consumed by Ansible
│   │   └── terraform.tfvars.example
│   └── modules/
│       ├── proxmox-template/  # downloads Ubuntu image, creates template VM (ID 9000)
│       └── proxmox-vm/        # clones template, sets cloud-init, static IP
├── ansible/
│   ├── kubespray/             # cloned at pipeline runtime — NOT in git
│   ├── inventory/
│   │   ├── generated/         # .gitignored — built from TF output at runtime
│   │   └── group_vars/all/
│   │       ├── all.yml        # SSH user, become, timeouts
│   │       └── kubespray.yml  # K8s version, CNI, addons
│   ├── playbooks/
│   │   ├── pre-k8s.yml        # OS prep: wait for cloud-init, swap off, sysctl
│   │   └── post-k8s.yml       # fetch kubeconfig, patch server URL, verify nodes
│   └── scripts/
│       └── generate_inventory.py   # TF JSON → Kubespray hosts.yaml
├── docs/                      # lab book — see below
├── tests/
│   ├── fixtures/terraform-output.json
│   └── test_generate_inventory.py  # 14 tests, IPs derived from fixture
└── kubeconfig/                # .gitignored — written by post-k8s.yml
```

## VM topology

| VM | Role | vCPU | RAM | Disk | IP |
|---|---|---|---|---|---|
| k8s-cp-01 | Control Plane | 2 | 4 GB | 30 GB | 192.168.1.201 |
| k8s-worker-01 | Worker | 2 | 6 GB | 40 GB | 192.168.1.202 |
| k8s-worker-02 | Worker | 2 | 6 GB | 40 GB | 192.168.1.203 |

Template VM (not a cluster node): ID 9000, `ubuntu-24.04-cloud`

## Kubernetes configuration

| Setting | Value |
|---|---|
| Version | v1.31.4 |
| CNI | Calico, IPIP Always |
| Container runtime | containerd |
| DNS | CoreDNS |
| etcd | co-located with control plane (kubeadm) |
| Helm | enabled |
| Metrics Server | enabled |
| Pod CIDR | 10.233.64.0/18 |
| Service CIDR | 10.233.0.0/18 |

## Kubespray

Kubespray is **not** stored as a git submodule. The `ansible-deploy.yml` workflow
clones it at runtime:

```bash
git clone --branch v2.26.0 --depth 1 \
  https://github.com/kubernetes-sigs/kubespray.git \
  ansible/kubespray
```

The version is pinned to tag `v2.26.0` (Kubernetes v1.31.x). To upgrade, see
[Chapter 12 — Upgrades & Next Steps](docs/12-upgrades-next-steps.md).

## Configuration — secrets and variables

No `terraform.tfvars` is used in CI. All configuration is injected via
Forgejo repository settings. `terraform.tfvars` is `.gitignored`.

### Forgejo Secrets (Settings → Secrets)

| Secret | Purpose |
|---|---|
| `PROXMOX_VE_ENDPOINT` | `https://<your-proxmox-ip>:8006` |
| `PROXMOX_VE_API_TOKEN` | `terraform@pam!ci=<uuid>` |
| `RUSTFS_ACCESS_KEY` | Terraform state backend credentials |
| `RUSTFS_SECRET_KEY` | Terraform state backend credentials |
| `RUSTFS_ENDPOINT` | RustFS S3 endpoint, e.g. `http://<your-truenas-ip>:30293`. Passed to `terraform init` via `-backend-config` — cannot be a `var.*` because the backend block is resolved before variables. |
| `PROXMOX_SSH_PRIVATE_KEY` | bpg/proxmox provider SSH → Proxmox host **only**. Public half in `root@proxmox:~/.ssh/authorized_keys`. Never touches a VM. |
| `ANSIBLE_SSH_PRIVATE_KEY` | Ansible SSH → K8s VMs **only**. Written to runner disk during deploy; deleted immediately after. Never authorised on Proxmox. |
| `ANSIBLE_SSH_PUBLIC_KEY` | Public half of `ANSIBLE_SSH_PRIVATE_KEY`. Injected into K8s VMs via cloud-init. |

### Forgejo Variables (Settings → Variables)

All IP variables are **required** — there are no defaults. Choose addresses that
are free on your LAN and outside your DHCP range.

| Variable | Example / notes |
|---|---|
| `TF_VAR_PROXMOX_NODE` | Your Proxmox node name — check Proxmox UI |
| `TF_VAR_NETWORK_GATEWAY` | Your LAN router IP |
| `TF_VAR_NETWORK_BRIDGE` | Proxmox bridge, e.g. `vmbr0` — check Proxmox UI → Network |
| `TF_VAR_CP01_IP` | Free static IP for the control-plane VM |
| `TF_VAR_WORKER01_IP` | Free static IP for worker-01 |
| `TF_VAR_WORKER02_IP` | Free static IP for worker-02 |
| `TF_VAR_DISK_DATASTORE` | `local-lvm` (or your datastore name — Proxmox UI → Storage) |
| `TF_VAR_IMAGE_DATASTORE` | `local` (must accept ISO content) |
| `TF_VAR_PROXMOX_TLS_INSECURE` | `true` for self-signed certs (Proxmox default) |

## Deployment order

### Prerequisites (one-time)

1. Create the `terraform-state` bucket in RustFS — see [Chapter 04 — RustFS State Backend](docs/04-rustfs-state-backend.md)
2. Configure Proxmox user, role, API token, and SSH key — see [Chapter 03 — Proxmox Prep](docs/03-proxmox-prep.md)
3. Provision and register the `proxmox-infra` runner LXC — see [Chapter 05 — Forgejo Runner](docs/05-forgejo-runner.md)
4. Set all secrets and variables in Forgejo repository settings

### Every deploy

1. Open a PR touching `terraform/` → `terraform-plan.yml` runs automatically, review the plan output
2. Merge PR → trigger **Terraform — Apply** manually (Actions tab, `workflow_dispatch`)
   - Leave `terraform_action` as `apply`
   - Expect ~20 min for VM disk cloning
3. Verify 4 resources in Proxmox: template (ID 9000) + cluster VMs (201, 202, 203)
4. Trigger **Ansible — Deploy K8s Cluster** manually
   - Leave both inputs blank (full install)
   - Expect ~40 min for Kubespray
5. Download the `kubeconfig-homelab` artifact from the completed workflow run
6. See [Chapter 08 — kubectl Access](docs/08-kubectl-access.md) for placement and verification steps

All three nodes should show `Ready`.

## State backend

Terraform state lives in RustFS on TrueNAS:

| Setting | Value |
|---|---|
| Endpoint | Set via `RUSTFS_ENDPOINT` Forgejo secret |
| Bucket | `terraform-state` |
| Key | `k8s-infra/homelab/terraform.tfstate` |

The endpoint is passed to `terraform init` via `-backend-config` flags in CI,
or via `backend.hcl` for local runs (see `backend.hcl.example`).
Credentials are passed via `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from
the Forgejo secrets.

## Workflow details

### terraform-plan.yml
Runs automatically on PRs that touch `terraform/`. Runs `terraform init` and
`terraform plan -no-color`, uploading the output as `plan.txt` artifact. No state
is modified. Safe to run on every PR.

### terraform-apply.yml
Manual trigger only. Runs `terraform apply -auto-approve`. Supports
`terraform destroy` via the `terraform_action` input (choose `apply` or
`destroy` from the dropdown). Serialized with `concurrency: cancel-in-progress: false`.

### ansible-deploy.yml
Manual trigger only. Clones Kubespray at runtime, builds a Python venv, runs
`pre-k8s.yml` → `cluster.yml` → `post-k8s.yml` in sequence. Uploads the
patched kubeconfig as the `kubeconfig-homelab` artifact (7-day retention).
Sensitive files (`~/.ssh/k8s_ansible`, generated inventory) are cleaned up in
an `always:` step. Serialized with `concurrency: cancel-in-progress: false`.

Optional inputs:
- `kubespray_tags` — pass Ansible tags to narrow the Kubespray run (blank = full install)
- `skip_preflight` — set to `true` to skip `pre-k8s.yml` if VMs were already prepared

### validate.yml
Runs automatically on every PR. Checks: `terraform fmt`, `terraform validate`,
Python syntax, YAML lint, and `pytest tests/`.

## Runner

The `proxmox-infra` runner is a dedicated LXC on Proxmox using a **host (shell)
executor** — no Docker or nesting required.

Required tools: Terraform ≥ 1.6, Python 3 + venv, kubectl, Node.js 22,
Forgejo runner binary registered with label `proxmox-infra:host`.

Full setup: [Chapter 05 — Forgejo Runner](docs/05-forgejo-runner.md)

## Documentation

The `docs/` directory is structured as a sequential junior-developer lab book.

**Chapters 01–08** are guided labs — follow in order on first setup:

| Chapter | Contents |
|---|---|
| [01 — Concepts & Architecture](docs/01-concepts.md) | Mental model: Proxmox, Terraform, Ansible, Kubespray, Forgejo |
| [02 — Lab Environment](docs/02-lab-environment.md) | Hardware layout, IP map, where to run each command |
| [03 — Proxmox Prep](docs/03-proxmox-prep.md) | API user, token, SSH keypairs, Forgejo secrets |
| [04 — RustFS State Backend](docs/04-rustfs-state-backend.md) | S3 bucket for Terraform state |
| [05 — Forgejo Runner](docs/05-forgejo-runner.md) | Runner LXC provisioning and registration |
| [06 — Terraform VMs](docs/06-terraform-vms.md) | VM provisioning, plan/apply, recovery |
| [07 — Ansible & Kubespray](docs/07-ansible-kubespray.md) | Kubernetes installation walkthrough |
| [08 — kubectl Access](docs/08-kubectl-access.md) | kubeconfig placement, verification |

**Chapters 09–12** are reference chapters — use when needed:

| Chapter | Contents |
|---|---|
| [09 — Operations Runbook](docs/09-operations-runbook.md) | Day-to-day procedures, incident response |
| [10 — Troubleshooting Labs](docs/10-troubleshooting-labs.md) | Diagnosed failures with root cause and fix |
| [11 — Security & Key Rotation](docs/11-security-key-rotation.md) | Credential management, rotation procedures |
| [12 — Upgrades & Next Steps](docs/12-upgrades-next-steps.md) | Kubernetes upgrade path, ingress/storage/HA options |

**Appendices:**

| File | Contents |
|---|---|
| [appendix/adr.md](docs/appendix/adr.md) | Architecture Decision Records |
| [appendix/glossary.md](docs/appendix/glossary.md) | Definitions of every term used in the lab |
| [appendix/failure-labs.md](docs/appendix/failure-labs.md) | Intentional break/fix exercises |

**New to this stack?** Start with [docs/00-lab-overview.md](docs/00-lab-overview.md).
**Something broken?** Go to [Chapter 10 — Troubleshooting Labs](docs/10-troubleshooting-labs.md).
**Wondering why X is designed that way?** See [appendix/adr.md](docs/appendix/adr.md).

---

## What's next

### ✅ Completed

| Item |
|---|
| Proxmox VMs provisioned (template 9000, cluster VMs 201/202/203) |
| Kubernetes v1.31.4 installed via Kubespray v2.26.0 — cluster live and healthy |
| All three Forgejo workflows working (terraform-plan, terraform-apply, ansible-deploy) |
| validate.yml — fmt, validate, lint, pytest on every PR |
| Split SSH keypairs (k8s_proxmox + k8s_ansible) |
| `workflow_dispatch` inputs with `type:` field (Forgejo 15 requirement) |
| `terraform_action: choice` replacing old `destroy: string` |
| kubectl verified from LXC-Rocky10 — all nodes Ready, all pods Running |
| Workflow concurrency on terraform-apply + ansible-deploy |
| cloud-init rc=2 handled correctly in pre-k8s.yml |
| Lab book restructured into sequential numbered chapters (00–12 + appendix) |

### 🔲 Immediate — before next workflow run

| # | Item | Notes |
|---|---|---|
| 1 | **Commit `.terraform.lock.hcl`** | Retrieve from runner: `~/work/<repo>/k8s-infra/terraform/envs/homelab/.terraform.lock.hcl` |
| 2 | **Smoke-test fixed workflows** | Trigger `terraform-plan` on a no-op PR; confirm `plan.txt` artifact only, no binary `tfplan` |

### 🔲 Advanced — cluster capabilities

| Option | Effort | Entry point |
|---|---|---|
| Enable ingress-nginx | Low | `ingress_nginx_enabled: true` in kubespray.yml, re-run with `kubespray_tags: apps` |
| Persistent storage (NFS) | Medium | TrueNAS NFS export + `nfs-subdir-external-provisioner` StorageClass |
| HA control plane | High | VM 204 + kube-vip; see Chapter 12 for full decision framework |
