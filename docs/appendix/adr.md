# Architecture Decision Records

A log of significant technical decisions, the context that led to them, and
the alternatives that were considered. Written so future maintainers understand
*why* things are the way they are — not just *what* they are.

---

## ADR-001 — Monorepo structure

**Status:** Accepted

**Context:**
Terraform (VM provisioning) and Ansible (K8s installation) are separate tools
with separate dependencies. They could live in separate repos.

**Decision:**
Single monorepo (`k8s-infra`). Terraform and Ansible are subdirectories.

**Rationale:**
- A single PR can modify both Terraform (add a VM) and Ansible (update the
  playbook that configures it) atomically.
- One repo means one set of Forgejo secrets, one runner configuration, one
  place to look for everything.
- The project is operated by one person. Multi-repo overhead has no benefit.

**Consequences:**
The `terraform-plan.yml` workflow uses `paths:` filtering to only trigger on
`terraform/` changes, avoiding spurious plan runs when Ansible files change.

---

## ADR-002 — Runtime Kubespray clone instead of git submodule

**Status:** Accepted

**Context:**
Kubespray must be pinned to a specific version (`v2.26.0`) to match
`kube_version: v1.31.4`. Pinning options:
1. Git submodule
2. Runtime `git clone --branch <tag>`
3. Copy the entire Kubespray tree into the repo

**Decision:**
Runtime clone in the CI workflow step.

**Rationale:**
- Git submodules have known usability issues with GitHub Desktop on Windows
  (the operator's primary workstation). Submodule state is a common source
  of `git status` confusion and accidental uncommitted changes.
- Copying Kubespray into the repo (~50MB) would bloat the repo and make
  upgrades a massive diff.
- Runtime clone is transparent: the exact command is visible in the workflow
  YAML. The version is pinned by the branch tag, which maps to a git SHA.

**Trade-offs:**
- Every Ansible workflow run requires a network fetch from GitHub. If GitHub
  is unavailable, the workflow fails. Acceptable for a homelab.
- The clone adds ~30 seconds to the workflow start time.

---

## ADR-003 — Manual apply trigger, automatic plan

**Status:** Accepted

**Context:**
CI/CD can be configured to automatically apply Terraform on PR merge (full
GitOps), or require a manual trigger.

**Decision:**
`terraform plan` runs automatically on every PR touching `terraform/`.
`terraform apply` is always manual (`workflow_dispatch`).

**Rationale:**
- Automatic apply means a bad `.tf` file merged to `main` would destroy and
  recreate VMs without human review. In a homelab with real workloads, this
  is unacceptable downtime.
- The plan already provides the safety signal — a human reviews the plan diff
  before clicking Apply.
- This pattern ("plan on PR, apply manually") is industry-standard for
  infrastructure that has state (as opposed to stateless app deployments where
  automatic deploy is normal).

**Consequences:**
Apply must be triggered in the Forgejo UI under Actions → `Terraform — Apply`
→ Run workflow. Choose `terraform_action = apply` to provision, or
`terraform_action = destroy` to tear down.

---

## ADR-004 — Dedicated SSH keypairs per trust boundary

**Status:** Accepted (supersedes earlier single-keypair design)

**Context:**
The `bpg/proxmox` Terraform provider needs SSH access to the Proxmox host for
disk import. Ansible needs SSH access to the K8s VMs. Initially a single
keypair served both. This was identified as a trust-boundary violation: a
compromised K8s VM shell could potentially be leveraged to reach the Proxmox
hypervisor using the same credential.

**Decision:**
Two dedicated ed25519 keypairs:

- `k8s_proxmox` — authorised **only** on `root@proxmox-host`. Never written
  to disk on the runner; consumed in-memory by the Terraform provider env var.
- `k8s_ansible` — authorised **only** on `ubuntu@<k8s-vm>`. Written to
  `~/.ssh/k8s_ansible` during the Ansible workflow, deleted in the `always:`
  cleanup step. Never authorised on Proxmox.

**Rationale:**
A K8s VM compromise (container escape, vulnerable workload) gives an attacker
`ubuntu` + sudo on that VM. With a shared key, they'd also have the credential
that authorises root SSH on Proxmox — game over for the hypervisor. With split
keys, the Ansible private key found on a VM is useless on Proxmox, and the
Proxmox key is never on any VM or written to runner disk.

The cost is two extra Forgejo secrets and one extra key generation step.
For a homelab, that's acceptable. For a production environment it would be
mandatory.

**Consequences:**
Three Forgejo secrets replace two: `PROXMOX_SSH_PRIVATE_KEY`,
`ANSIBLE_SSH_PRIVATE_KEY`, `ANSIBLE_SSH_PUBLIC_KEY`. The old
`SSH_DEPLOY_PRIVATE_KEY` and `SSH_DEPLOY_PUBLIC_KEY` are deleted.
See [Chapter 03 — Proxmox Prep](../03-proxmox-prep.md) for the current key
generation procedure and [Chapter 11 — Security & Key Rotation](../11-security-key-rotation.md)
for rotation guidance.

---

## ADR-005 — RustFS (not MinIO) for Terraform state backend

**Status:** Accepted

**Context:**
Terraform state needs an S3-compatible backend that persists across CI
runner runs. Options: MinIO, RustFS, AWS S3, local file.

**Decision:**
RustFS on TrueNAS Scale.

**Rationale:**
- RustFS was already running on TrueNAS serving other purposes. No new service
  to provision.
- MinIO was explicitly excluded from the homelab constraints.
- AWS S3 would be external to the LAN — adding internet dependency and cost.
- Local file on the runner LXC would be lost if the LXC is recreated.

**Consequences:**
The Terraform S3 backend config requires several `skip_*` flags to disable
AWS-specific features that RustFS doesn't support (account ID resolution,
CRC32C checksums). These are documented in `terraform/envs/homelab/backend.tf`
and `docs/01-concepts.md`.

---

## ADR-006 — Single control plane (no HA)

**Status:** Accepted (revisit if workloads grow)

**Context:**
Kubernetes HA requires at least 3 control plane nodes and a virtual IP (VIP)
load balancer (kube-vip or HAProxy+Keepalived). Single CP is simpler.

**Decision:**
Single control plane node (`k8s-cp-01`, `192.168.1.201`) for the initial
deployment.

**Rationale:**
- 32 GB total RAM across the host. Three control plane nodes × 4 GB = 12 GB
  just for CP overhead, leaving 20 GB for workers and TrueNAS. Too tight.
- For a homelab dev environment, CP downtime during upgrades or host
  maintenance is acceptable.
- Kubespray supports adding a second CP later — the `group_vars` already
  have commented-out `kubeadm_control_plane_endpoint` for a future VIP.

**Path to HA:**
1. Add a second CP VM (ID 204, `192.168.1.204`) to Terraform.
2. Deploy kube-vip for the VIP (`192.168.1.100` is taken by Proxmox; use
   e.g. `192.168.1.210`).
3. Add the second CP to `kube_control_plane` inventory group.
4. Uncomment and set `kubeadm_control_plane_endpoint` in `kubespray.yml`.
5. Run Kubespray's `scale.yml` playbook.

---

## ADR-007 — Calico with IPIP Always mode

**Status:** Accepted

**Context:**
Kubernetes requires a CNI plugin for pod-to-pod networking. Options include
Calico (multiple modes), Flannel, Cilium, Weave.

**Decision:**
Calico with `calico_ipip_mode: Always`.

**Rationale:**
- Calico is Kubespray's well-supported default and handles both L3 routing
  and L2 overlay modes.
- IPIP Always is required when all nodes are on the same L2 segment (same
  subnet, connected to the same switch/bridge). Without IPIP, Calico tries
  to use BGP direct routing, which requires the underlying network to route
  pod CIDRs — a feature our simple home router does not have.
- Flannel was considered but Calico provides better NetworkPolicy support
  for future use cases.
- Cilium was considered but adds eBPF complexity unnecessary for a 3-node
  homelab.

**Consequences:**
Pod traffic between nodes is encapsulated in IP-in-IP. Minimal performance
impact on a gigabit LAN. No extra router configuration needed.

---

## ADR-008 — Forgejo 15 config-file runner registration

**Status:** Accepted (forced by Forgejo version)

**Context:**
Forgejo 15 changed runner registration from CLI flags to a config-file flow.
Old documentation (including many blog posts) describes the `--no-interactive`
flag which no longer exists.

**Decision:**
Use `forgejo-runner generate-config > runner-config.yml`, edit the config
file directly, and start with `forgejo-runner daemon -c runner-config.yml`.

**Rationale:**
No alternative — Forgejo 15 removed the old registration CLI.

**Consequences:**
See `docs/05-forgejo-runner.md` for the full configuration template. The runner
label must be `proxmox-infra:host` (with `:host` suffix) — omitting the
executor type suffix prevents the runner from picking up `runs-on: [proxmox-infra]`
jobs.

---

## ADR-009 — `bpg/proxmox` over Telmate as the Terraform provider

**Status:** Accepted

**Context:**
Terraform needs a provider to manage Proxmox VE resources (VMs, templates, disk
images, cloud-init). No official Proxmox provider exists. Three community
providers are available:

| Provider | `registry.terraform.io` path |
|---|---|
| bpg/proxmox | `providers/bpg/proxmox` |
| Telmate/proxmox | `providers/Telmate/proxmox` |
| danitso/proxmox | `providers/danitso/proxmox` |

This repo requires two specific capabilities:
1. **Disk import** — downloading a cloud image and importing it into Proxmox
   storage as a VM disk. The Proxmox REST API does not expose this operation;
   it must be performed over SSH on the Proxmox host.
2. **cloud-init injection** — setting static IP, SSH authorised keys, and
   hostname at VM creation time via the cloud-init drive.

**Decision:**
Use `bpg/proxmox`.

**Rationale:**

| Criterion | bpg/proxmox | Telmate/proxmox | danitso/proxmox |
|---|---|---|---|
| Proxmox VE 8.x support | ✅ Full | ⚠️ Partial | ❌ Unmaintained |
| Disk import via SSH | ✅ Supported | ❌ Not supported | ❌ Not supported |
| cloud-init support | ✅ Full | ⚠️ Incomplete | ❌ Not supported |
| Active maintenance (2024–2025) | ✅ Yes | ⚠️ Stalled | ❌ Archived |
| Terraform Registry presence | ✅ Published | ✅ Published | ✅ Published |

Telmate is the most referenced provider in older tutorials and blog posts, but
its maintenance has stalled since approximately 2023. Disk import — which is
required to get a cloud image into Proxmox storage before cloning — is not
supported by Telmate; it would require a manual `qm importdisk` step outside
Terraform, breaking the goal of fully automated provisioning. The `danitso`
provider is unmaintained and was ruled out immediately.

`bpg/proxmox` supports both disk import (via SSH) and full cloud-init
configuration, which is why the provider block requires both an API token
and an SSH private key. This dual-credential requirement is a direct
consequence of choosing the provider that can perform the full workflow.

**Consequences:**
- Two SSH keypairs are required (see ADR-004): `k8s_proxmox` for the provider
  SSH channel, `k8s_ansible` for Ansible.
- The `~> 0.109.0` version pin must be reviewed when the provider reaches
  v1.0, which will remove the deprecated
  `proxmox_virtual_environment_download_file` resource name in favour of the
  shorter `proxmox_download_file` alias.
- Tutorials that use Telmate resource names (`proxmox_vm_qemu`, etc.) are not
  compatible with this repo. The bpg resource names all begin with
  `proxmox_virtual_environment_`.
