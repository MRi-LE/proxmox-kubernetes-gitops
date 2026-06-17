# Chapter 06 — Terraform VMs

**Goal:** Three Kubernetes VMs (201, 202, 203) and a Ubuntu template (9000)
provisioned on Proxmox via the `terraform-apply` workflow.

**You will learn:** How Terraform plans and applies work in this repo, what the
module structure does, how to read a Terraform plan, and how to recover from a
partial apply.

**Prerequisites:** [Chapter 05 — Forgejo Runner](05-forgejo-runner.md). All eight
Forgejo secrets and nine Forgejo variables must be set (see Chapter 02).

**Where to run commands:**

| Step | Run on | How |
|---|---|---|
| Review `.tf` files | Your workstation | Git client / editor |
| Trigger `terraform-plan` | Forgejo web UI | Open a PR |
| Read plan output | Forgejo web UI | Actions tab → plan run → logs |
| Trigger `terraform-apply` | Forgejo web UI | Actions → workflow_dispatch |
| Verify VMs created | Proxmox web UI | `192.168.1.100:8006` |
| Recovery commands | Runner LXC | SSH + `terraform` CLI |

---

## Terraform provider: `bpg/proxmox`

### What a provider is

Terraform itself is a planning and state engine — it knows nothing about
Proxmox, AWS, or any other platform. That platform-specific knowledge lives in
a **provider**: a plugin binary that Terraform downloads at `init` time and
calls when it needs to create, read, update, or destroy resources. The provider
translates Terraform's resource declarations into API calls (or SSH commands)
against the target platform.

Every provider is declared in `required_providers`:

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.109.0"
    }
  }
}
```

`source = "bpg/proxmox"` tells Terraform to fetch the plugin from
`registry.terraform.io/bpg/proxmox`. The `~> 0.109.0` constraint allows patch
releases (`0.109.1`, `0.109.2`, …) but blocks minor bumps (`0.110.0`),
preventing unexpected breaking changes in CI. When upgrading, check the
[provider changelog on GitHub](https://github.com/bpg/terraform-provider-proxmox/releases) first.

---

### What `bpg/proxmox` does for this project

The `bpg/proxmox` provider bridges Terraform and the Proxmox VE hypervisor.
It exposes Proxmox objects — VMs, templates, disk images, network bridges,
storage — as first-class Terraform resources that can be created, modified,
and destroyed via `terraform apply`.

The resources used in this repo are:

| Resource | Module | What it does |
|---|---|---|
| `proxmox_virtual_environment_download_file` | `proxmox-template` | Downloads the Ubuntu 24.04 cloud image into Proxmox storage |
| `proxmox_virtual_environment_vm` (template) | `proxmox-template` | Converts the downloaded image into a reusable cloud-init template (VM ID 9000) |
| `proxmox_virtual_environment_vm` (VMs) | `proxmox-vm` | Clones the template into three K8s cluster VMs (IDs 201–203), injects SSH key, static IP, and hostname via cloud-init |

The provider uses **two access methods simultaneously** because the Proxmox API
and SSH cover different, non-overlapping operations:

| Access method | Credential | Used for |
|---|---|---|
| Proxmox REST API | `PROXMOX_VE_API_TOKEN` | All standard VM lifecycle operations: create, configure, start, stop, destroy |
| SSH into Proxmox host | `PROXMOX_SSH_PRIVATE_KEY` | Low-level disk import and template conversion — operations the REST API cannot perform |

Removing either credential breaks a different subset of apply steps. Both are
required. See [Chapter 03 — Proxmox Prep](03-proxmox-prep.md) for how both
are provisioned.

---

### Alternative providers considered

Three community Terraform providers exist for Proxmox VE. Proxmox Server
Solutions GmbH does not publish an official provider.

| Provider | Registry source | Status | Why not chosen |
|---|---|---|---|
| **bpg/proxmox** ✅ | [`registry.terraform.io/providers/bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest) | Actively maintained; full Proxmox VE 7.x and 8.x coverage; cloud-init, disk import, network, firewall, storage | **Chosen** — see [ADR-009](appendix/adr.md#adr-009--bpgproxmox-over-telmate) |
| **Telmate/proxmox** | [`registry.terraform.io/providers/Telmate/proxmox`](https://registry.terraform.io/providers/Telmate/proxmox/latest) | The original community provider; most older tutorials reference it. Maintenance has slowed significantly since ~2023; Proxmox VE 8 parity gaps; incomplete cloud-init and disk-import support; open issues accumulating | Not chosen — cloud-init and disk-import gaps are blocking for this repo's template workflow |
| **danitso/proxmox** | [`registry.terraform.io/providers/danitso/proxmox`](https://registry.terraform.io/providers/danitso/proxmox/latest) | Experimental; low adoption; unmaintained | Not chosen — abandoned |

> **Note:** Provider choice is a long-term commitment. Changing providers
> requires rewriting all resource blocks. Choosing an actively maintained
> provider with solid Proxmox VE 8 support matters more than familiarity with
> Telmate-based tutorials.

---

### Official sources for `bpg/proxmox`

| Source | What it covers |
|---|---|
| [Terraform Registry — bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest/docs) | Full resource and data source reference; provider configuration options |
| [Resource: `proxmox_virtual_environment_download_file`](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_download_file) | Used in `proxmox-template` module to fetch the Ubuntu cloud image |
| [Resource: `proxmox_virtual_environment_vm`](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm) | Used in both modules — template creation and VM cloning |
| [GitHub — bpg/terraform-provider-proxmox](https://github.com/bpg/terraform-provider-proxmox) | Source code, issue tracker, release notes |
| [Provider docs site](https://bpg.github.io/terraform-provider-proxmox/) | Guides, examples, migration notes between major versions |
| [ADR-009](appendix/adr.md#adr-009--bpgproxmox-over-telmate) | Decision record: why `bpg/proxmox` was chosen over Telmate |

---

## Understanding the module structure

```
terraform/
├── envs/homelab/
│   ├── main.tf        ← calls modules, configures provider and backend
│   ├── variables.tf   ← declares all input variables (IPs, node name, etc.)
│   ├── outputs.tf     ← exports VM IPs as JSON for Ansible to consume
│   └── backend.tf     ← RustFS S3 backend config
└── modules/
    ├── proxmox-template/  ← downloads Ubuntu 24.04 image, creates template VM 9000
    └── proxmox-vm/        ← clones template, configures cloud-init, sets static IP
```

`main.tf` calls `proxmox-template` once and `proxmox-vm` three times (once per
cluster VM). All three VMs are identical in structure — only the name, IP, VM ID,
and RAM differ.

---

## The `terraform-plan` workflow (automatic on PR)

When you open a PR, `terraform-plan.yml` runs automatically. It:

1. Checks out the repo
2. Initialises Terraform (`terraform init -reconfigure`) against the RustFS backend
3. Runs `terraform plan -no-color > plan.txt`
4. Uploads `plan.txt` as a CI artifact

**What to look for in the plan output:**

- `No changes. Your infrastructure matches the configuration.` — the cluster VMs
  already exist and match what's in the `.tf` files. Safe to merge.
- Lines beginning `+` — resources that will be created.
- Lines beginning `-` — resources that will be destroyed.
- Lines beginning `~` — resources that will be modified in-place.
- `Objects have changed outside of Terraform` — drift detected. Someone or
  something modified Proxmox outside of Terraform. Investigate before applying.

**Download the plan artifact:**
Actions tab → `terraform-plan` run → Artifacts → `terraform-plan-text` → download `plan.txt`.

---

## The `terraform-apply` workflow (manual only)

Navigate to Forgejo → Actions → **Terraform — Apply** → click **Run workflow**.

The dropdown shows two choices:

| `terraform_action` | What it does |
|---|---|
| `apply` | Creates/updates VMs to match `.tf` files |
| `destroy` | Deletes all Terraform-managed resources (VMs + template) |

**Always review the plan output first.** There is no confirmation prompt after
clicking apply — it runs immediately.

Expected timeline for a fresh `apply` (first run, no VMs exist):

| Step | Time |
|---|---|
| `terraform init` | ~30 seconds |
| Download Ubuntu 24.04 cloud image | ~3–5 minutes (cached on subsequent runs) |
| Create template VM 9000 | ~2 minutes |
| Clone + configure VMs 201, 202, 203 | ~15–25 minutes |
| **Total** | **~25–35 minutes** |

---

## Successful run: what good looks like

A fresh apply (no existing VMs) has three visible stages in the Forgejo Actions log.

### Stage 1 — Cloud image downloaded and template created

```
module.ubuntu_template.proxmox_virtual_environment_download_file.ubuntu_cloud_image: Creating...
module.ubuntu_template.proxmox_virtual_environment_download_file.ubuntu_cloud_image: Creation complete after 53s [id=local:iso/ubuntu-24.04-cloud.img]
module.ubuntu_template.proxmox_virtual_environment_vm.template: Creating...
module.ubuntu_template.proxmox_virtual_environment_vm.template: Creation complete after 23s [id=9000]
```

The download time varies with your internet connection and whether the image is
already cached. On subsequent applies, if the image is already in Proxmox,
Terraform skips the download (`overwrite = false`).

### Stage 2 — Three VMs cloned in parallel

All three VMs clone from the template simultaneously. The log will show
interleaved `Still creating...` lines for all three. This is normal — they are
not sequential. Expect 10–16 minutes on typical homelab storage.

```
module.k8s_cp_01.proxmox_virtual_environment_vm.vm: Creation complete after 15m57s [id=201]
module.k8s_worker_01.proxmox_virtual_environment_vm.vm: Creation complete after 15m56s [id=202]
module.k8s_worker_02.proxmox_virtual_environment_vm.vm: Creation complete after 15m56s [id=203]
```

### Stage 3 — Apply summary and outputs

```
Apply complete! Resources: 5 added, 0 changed, 0 destroyed.

Outputs:

ansible_ssh_user = "ubuntu"
control_plane_ip = "192.168.1.201"
control_planes   = ["k8s-cp-01"]
template_name    = "ubuntu-24.04-cloud"
template_vm_id   = 9000
vm_ips = {
  "k8s-cp-01"     = "192.168.1.201"
  "k8s-worker-01" = "192.168.1.202"
  "k8s-worker-02" = "192.168.1.203"
}
vm_names = ["k8s-cp-01", "k8s-worker-01", "k8s-worker-02"]
workers  = ["k8s-worker-01", "k8s-worker-02"]
```

`Resources: 5 added` on a fresh deploy (1 cloud image download + 1 template VM
+ 3 cluster VMs). On a subsequent apply with no changes the number will be 0.

**Terraform → Ansible output contract:**

These outputs are the handoff point between Terraform and Ansible. The
`ansible-deploy` workflow runs `terraform output -json` and pipes the result
to `generate_inventory.py`, which builds `hosts.yaml` for Kubespray.

| Output | Type | Consumed by | Purpose |
|---|---|---|---|
| `vm_ips` | `map(string)` | `generate_inventory.py` | VM name → IP — populates `ansible_host`, `ip`, `access_ip` per host |
| `control_planes` | `list(string)` | `generate_inventory.py` | VM names assigned to `kube_control_plane` and `etcd` groups |
| `workers` | `list(string)` | `generate_inventory.py` | VM names assigned to the `kube_node` group |
| `ansible_ssh_user` | `string` | `generate_inventory.py` | Username set by cloud-init — written as `ansible_user` on every host. Defaults to `ubuntu`. Changing the base image without updating this variable will break all Ansible SSH connections silently. |
| `control_plane_ip` | `string` | `post-k8s.yml` | IP of the control plane — used to patch the kubeconfig server URL from `127.0.0.1:6443` to the real LAN address |
| `template_name` | `string` | Informational | Name of the Proxmox template — useful to verify in Proxmox UI |
| `template_vm_id` | `number` | Informational | Proxmox VM ID of the template (default 9000) — useful when freeing the ID |
| `vm_names` | `list(string)` | Informational | All VM names — not read by `generate_inventory.py` (which derives names from `vm_ips` keys) |

In the Proxmox web UI you should see:
- VM `9000` — `ubuntu-24.04-cloud` (stopped, marked as template)
- VM `201` — `k8s-cp-01` (running)
- VM `202` — `k8s-worker-01` (running)
- VM `203` — `k8s-worker-02` (running)

---

## Known harmless Terraform warnings

A successful apply produces three categories of warnings. They do not affect
the result as long as `Apply complete!` appears and all VMs are running.

| Warning | Meaning | Action |
|---|---|---|
| `Use "proxmox_download_file" instead. This resource / data source will be removed in v1.0.` | The `proxmox_virtual_environment_download_file` resource is deprecated in the `bpg/proxmox` provider. The replacement (`proxmox_download_file`) will be required when the provider reaches v1.0. | Ignore while pinned to `~> 0.109.0`. Update the module when upgrading the provider to v1.0. |
| `The deprecation originates from module.ubuntu_template.proxmox_virtual_environment_download_file...` | A follow-on warning from the above, surfaced because the deprecated resource's ID is referenced by the template VM. | Same — ignore until provider upgrade. |
| `timeout while waiting for the QEMU agent on VM "202" to publish the network interfaces` | After cloning, the bpg/proxmox provider waits for the QEMU guest agent to report the VM's IP. The agent starts after cloud-init runs, which takes 30–90 seconds. The provider's wait window sometimes expires before the agent is ready. | Ignore if the VM is running and reachable by SSH. The VM itself is fine; the provider just couldn't confirm the IP in time. |

**Rule:** warnings before `Apply complete!` are informational. Warnings that
appear *instead of* `Apply complete!`, or are accompanied by `Error:`, are
failures and must be diagnosed.

---

## Verify VMs are reachable

From the runner LXC, ping all three VMs before proceeding to Ansible:

```bash
ping -c 2 192.168.1.201
ping -c 2 192.168.1.202
ping -c 2 192.168.1.203
```

If ping fails after 5 minutes, the VMs are still booting or cloud-init is still
running. Wait and retry. If they're still unreachable after 10 minutes, check
the Proxmox console for the VM (`qm terminal 201`) — common causes are
cloud-init failure or wrong gateway IP.

---

## Recovery: partial apply

If the apply workflow times out or is cancelled mid-run, some VMs may exist in
Proxmox but not in state, or vice versa.

**Step 1 — Check what Proxmox sees:**
```bash
# On the Proxmox host
qm list
```

**Step 2 — Check what Terraform state sees (on runner LXC):**
```bash
cd $GITHUB_WORKSPACE/terraform/envs/homelab
terraform state list
```

**Step 3 — Remove orphaned VMs from Proxmox (if not in state):**
```bash
# On Proxmox host
qm stop 201 --skiplock 2>/dev/null || true
qm destroy 201 --destroy-unreferenced-disks 1 --purge 1
# Repeat for 202, 203, 9000 as needed
```

**Step 4 — Remove from Terraform state if Proxmox no longer has them:**
```bash
terraform state rm module.k8s_cp_01.proxmox_virtual_environment_vm.vm
terraform state rm module.k8s_worker_01.proxmox_virtual_environment_vm.vm
terraform state rm module.k8s_worker_02.proxmox_virtual_environment_vm.vm
```

**Step 5 — Re-trigger the apply workflow.**

The template VM (`9000`) and its cloud image download are safe to leave in state
if they completed successfully — Terraform will skip them on the next run.

---

## The `.terraform.lock.hcl` file

This file records the exact provider versions and their checksums. It should be
committed to git so that every CI run uses identical providers.

**Retrieve it from the runner workspace after the first successful `terraform init`:**

```bash
# On the runner LXC, find the workspace
ls ~/work/<repo>/k8s-infra/terraform/envs/homelab/.terraform.lock.hcl

# Copy to your workstation (via scp) or cat and paste into a local file:
cat ~/work/<repo>/k8s-infra/terraform/envs/homelab/.terraform.lock.hcl
```

Commit it to `main` directly (it's not a secret — it contains only provider
hashes, not credentials). After committing, subsequent `terraform init` runs will
verify providers against these hashes automatically.

---

## `terraform.tfvars` — what it is, when you need it, when you don't

### What it is

`terraform.tfvars` is an optional local file that supplies values for Terraform
input variables. When Terraform runs, it automatically reads this file if it
exists and uses its values to fill in any `variable` blocks that have no
`default`.

It is the local equivalent of Forgejo Variables and Secrets: the same values,
just stored in a file on your workstation rather than in Forgejo.

### The two ways variables get their values in this repo

| Context | How variables are supplied |
|---|---|
| **CI (Forgejo workflows)** | Forgejo Secrets and Variables inject values via `TF_VAR_*` environment variables and `-backend-config` flags. No `terraform.tfvars` is present on the runner. |
| **Local runs** (optional) | `terraform.tfvars` on your workstation supplies the same values so you can run `terraform plan` or `terraform apply` directly from your machine without going through CI. |

### You do not have this file — that is correct

The repo only contains `terraform.tfvars.example`. The real `terraform.tfvars`
is in `.gitignore` because it contains secrets (API token, SSH private key).
It is never committed.

If you are only using CI to run Terraform (the intended workflow for this repo),
**you do not need to create `terraform.tfvars` at all.** The Forgejo workflow
supplies everything the runner needs.

### What happens without it

Without a `terraform.tfvars`, running `terraform plan` locally will fail for
every required variable that has no default — Terraform will prompt you for
each value interactively, or error if run with `-input=false`.

Required variables in this repo (no default, must be supplied somehow):

```
proxmox_endpoint, proxmox_api_token, proxmox_ssh_private_key,
ansible_ssh_public_key, network_gateway, network_bridge,
cp01_ip, worker01_ip, worker02_ip
```

In CI these are satisfied by `TF_VAR_*` environment variables set from Forgejo
Secrets and Variables. Locally they would be satisfied by `terraform.tfvars`.

### If you want to run Terraform locally

Copy the example file and fill in your real values:

```bash
cp terraform/envs/homelab/terraform.tfvars.example \
   terraform/envs/homelab/terraform.tfvars
# edit terraform.tfvars with your real values — never commit it
```

You also need `backend.hcl` for the S3 backend (see `backend.hcl.example`),
then initialise with:

```bash
cd terraform/envs/homelab
terraform init -backend-config=backend.hcl
terraform plan
```

---

## Module configuration reference

All variables configurable from `terraform.tfvars` are described in
`terraform/envs/homelab/variables.tf`. The table below covers every variable
the module layer exposes, why it exists, and whether you need to touch it.

### Wired — set in `terraform.tfvars`

These are passed from `envs/homelab/variables.tf` all the way through to the
modules. Change them freely; they do not require editing `.tf` files.

| Variable | Default | When to change |
|---|---|---|
| `disk_datastore` | `local-lvm` | Your Proxmox storage is named differently — check Proxmox UI → Datacenter → Storage |
| `image_datastore` | `local` | Your ISO/image storage is on a NAS or differently named datastore |
| `proxmox_tls_insecure` | `true` | Set `false` only if Proxmox has a valid, non-self-signed TLS certificate |

### Module defaults — not in `tfvars`, not in `main.tf`

These exist as module-level variables with fixed defaults. They are correct for
this lab and for most homelab Proxmox setups. **Do not add them to
`terraform.tfvars`** — the root module has no matching variable declaration and
Terraform will error with `Value for undeclared variable`.

To change them, edit the relevant module call in `terraform/envs/homelab/main.tf`
directly and add a corresponding root variable if you want the change to be
configurable.

| Variable | Module | Default | Notes |
|---|---|---|---|
| `cidr_prefix` | `proxmox-vm` | `24` | Prefix length for VM static IPs. /24 covers all `192.168.x.x` homelab setups |
| `dns_servers` | `proxmox-vm` | `["1.1.1.1", "8.8.8.8"]` | Injected into VMs via cloud-init |
| `ubuntu_image_url` | `proxmox-template` | Ubuntu 24.04 release URL | Part of the pinned lab design. Changing also requires updating the checksum |
| `ubuntu_image_checksum` | `proxmox-template` | SHA-256 of the above | Must match the image URL exactly — regenerate with the command in the module file |

---

## Checkpoint questions

1. What is the difference between `terraform plan` and `terraform apply`?
2. A plan shows `~ update in-place` on a VM. Should you be worried? What does that mean?
3. Why is `terraform-apply` a `workflow_dispatch` trigger and not automatic on merge?
4. The apply fails at 22 minutes with a timeout. What do you do first?
5. What does the `.terraform.lock.hcl` file contain, and why must it be committed?

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| VM IDs 201–203 already taken on Proxmox node | `resource already exists` error during apply | Free the IDs in Proxmox UI, or edit the `vm_id` values in `terraform/envs/homelab/main.tf` |
| `terraform.tfvars` accidentally committed | Credentials visible in git history | Rotate all committed secrets; remove file with `git filter-repo` |
| Apply triggered without reviewing plan | Unexpected destroy of existing VMs | Always read the plan artifact first |
| `.terraform.lock.hcl` not committed | Providers may resolve to different versions in CI vs local | Commit the lock file from runner workspace |
| `timeout-minutes` too low (< 60) | Apply killed mid-VM-clone | Increase in `terraform-apply.yml` |

---

*Previous: [Chapter 05 — Forgejo Runner](05-forgejo-runner.md) · Next: [Chapter 07 — Ansible & Kubespray](07-ansible-kubespray.md)*
