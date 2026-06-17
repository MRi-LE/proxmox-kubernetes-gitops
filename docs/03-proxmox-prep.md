# Chapter 03 — Proxmox Prep

**Goal:** Have Proxmox ready for Terraform — API user created, API token issued,
SSH key authorised, and all eight Forgejo secrets populated.

**You will learn:** How Proxmox access control works (users, groups, roles, tokens),
why we use two SSH keypairs, and how to verify each piece before triggering any workflow.

**Prerequisites:** [Chapter 02 — Lab Environment](02-lab-environment.md). Proxmox VE
must be installed and accessible at its web UI.

**Where to run commands:**

| Step | Run on | How to get there |
|---|---|---|
| `pveum` commands | Proxmox host | SSH: `ssh root@192.168.1.100` or Proxmox UI → Shell |
| SSH keygen | Your workstation | Local terminal |
| `ssh-copy-id` | Your workstation | After generating the keypair |
| Forgejo secrets | Forgejo web UI | Repository → Settings → Secrets |

---

Everything you need to fill in `terraform/envs/homelab/terraform.tfvars` and
configure the matching Forgejo secrets before running the first Terraform plan.

> **Note:** `vm_template` is no longer a manual input. Terraform now downloads
> the Ubuntu 24.04 cloud image and creates the template automatically via the
> `proxmox-template` module. You only need the values below.

---

## `terraform.tfvars` — value by value

### `proxmox_endpoint`

Open your Proxmox web UI in a browser. The URL in the address bar is your endpoint.

```hcl
proxmox_endpoint = "https://192.168.0.X:8006"
```

`8006` is always the Proxmox API port.

---

### Proxmox user, group, role, and API token

Terraform needs a dedicated Proxmox user with a scoped role — never use
`root@pam` in CI. The steps below create the `terraform` user, a `ci` group,
a `TerraformCI` role with the minimum required privileges, and the API token
that goes into Forgejo Secrets.

Run all `pveum` commands **on the Proxmox host** as root (SSH in or use the
Proxmox shell button in the UI).

#### 1. Create the group

```bash
pveum group add ci --comment "Terraform CI automation"
```

#### 2. Create the user and add it to the group

```bash
pveum user add terraform@pam --comment "Terraform CI" --groups ci
```

`@pam` puts the user in the PAM realm (Linux system auth). No password is
needed — the user will authenticate exclusively via API token.

#### 3. Create the role with required privileges

This is the privilege set from the official bpg/proxmox provider docs,
trimmed to what this setup actually uses (no HA, no SDN, no snippets):

```bash
pveum role add TerraformCI --privs \
  "Datastore.Allocate \
   Datastore.AllocateSpace \
   Datastore.AllocateTemplate \
   Datastore.Audit \
   Pool.Allocate \
   Pool.Audit \
   Sys.Audit \
   Sys.Console \
   Sys.Modify \
   VM.Allocate \
   VM.Audit \
   VM.Clone \
   VM.Config.CDROM \
   VM.Config.Cloudinit \
   VM.Config.CPU \
   VM.Config.Disk \
   VM.Config.HWType \
   VM.Config.Memory \
   VM.Config.Network \
   VM.Config.Options \
   VM.Migrate \
   VM.Monitor \
   VM.PowerMgmt"
```

#### 4. Assign the role to the group at the datacenter root

```bash
pveum aclmod / --group ci --role TerraformCI
```

Assigning at `/` (datacenter root) means the role applies to all nodes and
all datastores — required because Terraform creates resources across both
`local` (image download) and `local-lvm` (VM disks).

#### 5. Verify the ACL

```bash
pveum acl list
```

You should see a line with `group:ci`, role `TerraformCI`, path `/`.

#### 6. Create the API token

```bash
pveum user token add terraform@pam ci --privsep 0
```

`--privsep 0` disables privilege separation so the token inherits the full
role permissions. With privilege separation on (the default), the token gets
no privileges unless you explicitly assign them again — which is a common
source of 403 errors.

Output:

```
┌──────────────┬──────────────────────────────────────────┐
│ key          │ value                                    │
╞══════════════╪══════════════════════════════════════════╡
│ full-tokenid │ terraform@pam!ci                         │
├──────────────┼──────────────────────────────────────────┤
│ value        │ xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx     │
└──────────────┴──────────────────────────────────────────┘
```

**Copy the `value` UUID immediately — it is shown only once.**

#### 7. Rotate the token (if compromised)

If the token secret is ever exposed (e.g. committed to git history):

```bash
# Delete the old token
pveum user token remove terraform@pam ci

# Create a fresh one — new UUID will be issued
pveum user token add terraform@pam ci --privsep 0
```

Update the `PROXMOX_VE_API_TOKEN` Forgejo Secret with the new value before
triggering any workflow.

---

### `proxmox_api_token`

The token string is assembled from three parts:

```
<user>@<realm>!<token-id>=<uuid>
```

For the user and token created above:

```hcl
proxmox_api_token = "terraform@pam!ci=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

---

### `proxmox_node`

In the Proxmox web UI left sidebar, look at the node name directly under **Datacenter**:

```
Datacenter
  └── pve          ← this is the node name
        ├── local
        └── local-lvm
```

Usually `pve`, but it may match your machine's hostname if you renamed it.

```hcl
proxmox_node = "pve"
```

---

### `ssh_public_key` and the deploy keypair

Two dedicated keypairs are used — one per trust boundary. See [Chapter 11 — Security & Key Rotation](11-security-key-rotation.md) for the full rationale.

| Keypair | Where authorised | Forgejo secrets |
|---|---|---|
| `k8s_proxmox` | `root@proxmox` only | `PROXMOX_SSH_PRIVATE_KEY` |
| `k8s_ansible` | `ubuntu@<k8s-vm>` only | `ANSIBLE_SSH_PRIVATE_KEY`, `ANSIBLE_SSH_PUBLIC_KEY` |


#### Generate the keypairs (once)

Run on your local machine or the Forgejo runner LXC. Two separate keys,
one per trust boundary — never reuse the same key for both:

```bash
# Proxmox provider key — authorised on the Proxmox host only
ssh-keygen -t ed25519 -f ~/.ssh/k8s_proxmox -C "k8s-proxmox provider key" -N ""

# Ansible deploy key — injected into Kubernetes VMs only
ssh-keygen -t ed25519 -f ~/.ssh/k8s_ansible -C "k8s-ansible deploy key" -N ""
```

#### Authorise the Proxmox key on the Proxmox host

This is a **one-time manual step** on the Proxmox host. The bpg/proxmox
provider SSHes in as `root` to perform low-level operations (disk import,
template conversion) that the API alone cannot do.

```bash
# Authorise k8s_proxmox — NOT k8s_ansible
ssh-copy-id -i ~/.ssh/k8s_proxmox.pub root@192.168.1.100
```

Or paste manually if `ssh-copy-id` is not available:

```bash
# On the Proxmox host as root:
echo "ssh-ed25519 AAAA... k8s-proxmox provider key" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

> ⚠️ **Only `k8s_proxmox.pub` goes on the Proxmox host.**
> `k8s_ansible` is injected into Kubernetes VMs via cloud-init — it should
> never be authorised on Proxmox. Mixing them up defeats the security model.

Verify the provider can connect before triggering any workflow:

```bash
ssh -i ~/.ssh/k8s_proxmox root@192.168.1.100 echo ok
# Expected output: ok
```

#### Get the values for tfvars and Forgejo

```bash
# Public Ansible key — goes into terraform.tfvars and Forgejo secret
cat ~/.ssh/k8s_ansible.pub
# ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... k8s-ansible deploy key
```

```hcl
ansible_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... k8s-ansible deploy key"
```

`proxmox_ssh_private_key` in `terraform.tfvars` (for local runs only — CI uses
the `PROXMOX_SSH_PRIVATE_KEY` Forgejo secret):

```hcl
proxmox_ssh_private_key = <<EOT
<PASTE THE FULL CONTENT OF ~/.ssh/k8s_proxmox HERE>
EOT
```

> **Heredoc indentation warning:** use `<<EOT` (not `<<-EOT`) and do not
> indent the key body. Private key parsers treat leading spaces as part of the
> key content and will silently reject an indented key.

---

### `network_gateway`

The default gateway for your LAN — almost always your router's IP.
Confirm it from any machine already on the network:

```bash
ip route | grep default
# default via 192.168.0.1 dev eth0
```

```hcl
network_gateway = "192.168.0.1"
```

---

### `network_bridge`

The Proxmox bridge your LAN interface is attached to.
Confirm in the Proxmox web UI: **your node → Network**.
Unless you've added extra bridges, this is `vmbr0`.

```hcl
network_bridge = "vmbr0"
```

---

### `template_name` and `template_vm_id` (optional overrides)

Terraform creates the Ubuntu 24.04 template automatically — you do not need to
set these. The defaults in `variables.tf` are:

| Variable | Default | When to override |
|---|---|---|
| `template_name` | `ubuntu-24.04-cloud` | You want a different name |
| `template_vm_id` | `9000` | VM ID 9000 is already taken on your node |

To override, uncomment the relevant lines in `terraform.tfvars`.

---

### Cloud image checksum

The image URL and SHA-256 checksum are pinned in
`terraform/modules/proxmox-template/variables.tf`. Terraform verifies the
checksum before creating the template, so the image is never silently corrupt.

When Ubuntu releases a newer point release, update both values together:

```bash
# Get the latest checksum
curl -L https://cloud-images.ubuntu.com/releases/24.04/release/SHA256SUMS \
  | grep ubuntu-24.04-server-cloudimg-amd64.img
```

Then update `variables.tf` in the module and commit.

---

## Complete `terraform.tfvars`

Rather than maintaining a duplicate variable list here, use the annotated example file in the repo as your single source of truth:

```
terraform/envs/homelab/terraform.tfvars.example
```

Copy it, fill in your values, and save as `terraform.tfvars` in the same directory. Every variable is documented inline with its purpose, an example value, and notes on where to find the right value.

> `terraform.tfvars` is `.gitignored` — never commit it.
> The `.example` file is what lives in the repo.

---

## Forgejo secrets

Set these in your Forgejo repository under **Settings → Secrets**.
All eight are required before any workflow will succeed.

| Secret | Where to get the value |
|---|---|
| `PROXMOX_VE_ENDPOINT` | Same as `proxmox_endpoint` above |
| `PROXMOX_VE_API_TOKEN` | Same as `proxmox_api_token` above |
| `PROXMOX_SSH_PRIVATE_KEY` | `cat ~/.ssh/k8s_proxmox` |
| `ANSIBLE_SSH_PRIVATE_KEY` | `cat ~/.ssh/k8s_ansible` |
| `ANSIBLE_SSH_PUBLIC_KEY` | `cat ~/.ssh/k8s_ansible.pub` |
| `RUSTFS_ACCESS_KEY` | From your RustFS / TrueNAS configuration |
| `RUSTFS_SECRET_KEY` | From your RustFS / TrueNAS configuration |
| `RUSTFS_ENDPOINT` | RustFS S3 API URL, e.g. `http://192.168.1.50:30293`. Passed to `terraform init` via `-backend-config` — cannot be a `TF_VAR_*` because the backend block resolves before variables. |

> **Note on classification:** `RUSTFS_ENDPOINT` is environment configuration
> rather than a credential, and could logically live as a Forgejo Variable.
> It is stored as a Secret for now because the workflow already reads it from
> secrets; future cleanup could move non-sensitive endpoints and IPs to
> Variables alongside the existing `TF_VAR_*` entries.

---

## Pre-flight checklist

Before running `terraform init` or triggering any workflow:

- [ ] `ci` group created in Proxmox (`pveum group add ci`)
- [ ] `terraform@pam` user created and added to `ci` group
- [ ] `TerraformCI` role created with required privileges
- [ ] Role assigned to `ci` group at path `/` (datacenter root)
- [ ] API token `terraform@pam!ci` created with `--privsep 0`, UUID copied
- [ ] Proxmox keypair at `~/.ssh/k8s_proxmox`, Ansible keypair at `~/.ssh/k8s_ansible`
- [ ] `k8s_proxmox.pub` authorised on Proxmox host — verify with `ssh -i ~/.ssh/k8s_proxmox root@192.168.1.100 echo ok`
- [ ] `terraform.tfvars` filled in (from `.example`) and **not committed**
- [ ] `RUSTFS_ENDPOINT` set in Forgejo Secrets (CI) **or** `backend.hcl` filled in (local runs — see `backend.hcl.example`)
- [ ] All 8 Forgejo secrets set, all 9 Forgejo variables set (see Chapter 02)
- [ ] Forgejo runner LXC online with label `proxmox-infra` — see [Chapter 05 — Forgejo Runner](05-forgejo-runner.md)
- [ ] Branch protection enabled on `main`
- [ ] VM ID `9000` is free on your Proxmox node (template) and `201`, `202`, `203` are free (cluster VMs)

> No manual template creation needed — Terraform handles it on first `apply`.

---

## Checkpoint questions

1. What does `--privsep 0` do on the `pveum user token add` command? What breaks without it?
2. Why is the `TerraformCI` role assigned at path `/` (datacenter root) rather than on a specific datastore?
3. Why does `k8s_proxmox.pub` go on the Proxmox host but `k8s_ansible.pub` does not?
4. What happens if you mix up the two public keys (put `k8s_ansible.pub` on Proxmox)?
5. The API token UUID is shown only once. You forgot to copy it. What do you do?

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| `--privsep 0` omitted | Terraform gets 403 on all API calls despite correct token | Delete and recreate token with flag |
| `k8s_ansible.pub` placed on Proxmox host instead of `k8s_proxmox.pub` | bpg/proxmox SSH operations fail; VMs can't be managed | Correct `authorized_keys` on Proxmox host |
| Heredoc in `terraform.tfvars` indented (`<<-EOT`) | Private key rejected silently | Use `<<EOT` with no indentation on key body |
| Forgejo secret has trailing newline | Auth fails intermittently | Paste with `cat ~/.ssh/k8s_proxmox | tr -d '\n'` or check copy method |
| Role assigned to user directly instead of group | Works today, breaks if user is recreated | Reassign via `pveum aclmod / --group ci --role TerraformCI` |

---

*Previous: [Chapter 02 — Lab Environment](02-lab-environment.md) · Next: [Chapter 04 — RustFS State Backend](04-rustfs-state-backend.md)*
