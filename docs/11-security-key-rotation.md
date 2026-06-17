# Chapter 11 — Security & Key Rotation

**Goal:** Know what every credential does, where it's stored, and how to rotate
it without downtime. Know what has been (and must never be) committed to git.

**You will learn:** The blast radius of each credential if compromised,
how to audit git history for accidental secret exposure, and the step-by-step
rotation procedure for each secret.

**Prerequisites:** [Chapter 08 — kubectl Access](08-kubectl-access.md). You
should have a working cluster before testing key rotation.

**Where to run commands:**

| Task | Run on |
|---|---|
| Proxmox token rotation (`pveum`) | Proxmox host |
| SSH keypair rotation | Your workstation |
| Live key push (Ansible) | Runner LXC or workstation with Ansible installed |
| Forgejo secret updates | Forgejo web UI |
| Git history audit | Your workstation |

---


## What lives in git vs what does not

| Classification | Examples | In git? | Why |
|---|---|---|---|
| ✅ Templates & code | All `.tf`, `.yml`, `.py` files | Yes | These never contain real values |
| ✅ Example configs | `terraform.tfvars.example` | Yes | Placeholder values only |
| ✅ Lock files | `.terraform.lock.hcl` | Yes | Contains provider hashes, not secrets |
| ❌ Real tfvars | `terraform.tfvars` | **No** | Contains tokens and private keys |
| ❌ Generated inventory | `ansible/inventory/generated/` | **No** | Contains real IPs at runtime |
| ❌ Kubeconfig | `kubeconfig/homelab.yaml` | **No** | Contains cluster credentials |
| ❌ SSH keys | `~/.ssh/k8s_proxmox`, `~/.ssh/k8s_ansible` | **No** | Private keys must never be committed |
| ❌ Any secret | Tokens, passwords, UUIDs | **No** | Use Forgejo Secrets |

The `.gitignore` enforces most of these. Verify it hasn't drifted:

```bash
git check-ignore -v terraform/envs/homelab/terraform.tfvars
git check-ignore -v ansible/inventory/generated/hosts.yaml
git check-ignore -v kubeconfig/homelab.yaml
```

Each should report a matching `.gitignore` rule. If any returns nothing, the
file is untracked — add it to `.gitignore` and audit git history.

---

## Secret classification

### PROXMOX_VE_API_TOKEN

**What it is:** An API token issued by Proxmox in the format
`terraform@pam!ci=<uuid>`. The UUID half is the secret.

**What it can do:** Everything the `TerraformCI` role allows — create, modify,
and delete VMs and datastore objects. It cannot SSH into Proxmox (that's the
SSH key's job), modify Proxmox users, or access other VMs' consoles.

**Minimum privilege:** The `TerraformCI` role has only the VM and datastore
permissions needed for provisioning. It does not have `Sys.PowerMgmt`,
`SDN.*`, `Realm.*`, or any user-management privilege.

**Rotation:**
```bash
# On the Proxmox host as root:
pveum user token remove terraform@pam ci
pveum user token add terraform@pam ci --privsep 0
# Copy the new UUID — it's shown once only
```
Update `PROXMOX_VE_API_TOKEN` in Forgejo → Settings → Secrets before
triggering any workflow.

---

### PROXMOX_SSH_PRIVATE_KEY

**What it is:** An ed25519 private key (`~/.ssh/k8s_proxmox`). Its public half
is authorised **only** in `root@192.168.1.100:~/.ssh/authorized_keys`.

**What it can do:** SSH into the Proxmox host as `root`. Used exclusively by
the `bpg/proxmox` Terraform provider for disk import operations. It is never
written to disk on the runner or injected into any VM.

**Blast radius if compromised:** root on the Proxmox host. Rotate immediately.

**Rotation:**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/k8s_proxmox_new -C "k8s-proxmox provider key" -N ""
ssh-copy-id -i ~/.ssh/k8s_proxmox_new.pub root@192.168.1.100
ssh -i ~/.ssh/k8s_proxmox_new root@192.168.1.100 echo "new key works"
ssh root@192.168.1.100 "sed -i '/k8s-proxmox provider key/d' ~/.ssh/authorized_keys"
```
Update `PROXMOX_SSH_PRIVATE_KEY` in Forgejo Secrets.

---

### ANSIBLE_SSH_PRIVATE_KEY / ANSIBLE_SSH_PUBLIC_KEY

**What it is:** An ed25519 keypair (`~/.ssh/k8s_ansible`). The public half is
injected into every K8s VM's `ubuntu@<vm>:~/.ssh/authorized_keys` via
cloud-init at first boot. The private half is written to `~/.ssh/k8s_ansible`
on the runner during the Ansible workflow and deleted in the `always:` cleanup
step.

**What it can do:** SSH into K8s VMs as `ubuntu` (with passwordless sudo via
Kubespray). It is **not** authorised on the Proxmox host.

**Blast radius if compromised:** `ubuntu` + sudo on all three K8s VMs. Does
not reach Proxmox.

**Rotation:**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/k8s_ansible_new -C "k8s-ansible deploy key" -N ""
```
Then push the new public key live to running VMs (no rebuild needed):
```bash
ansible all -i ansible/inventory/generated/hosts.yaml \
  --private-key ~/.ssh/k8s_ansible \
  -m ansible.posix.authorized_key \
  -a "user=ubuntu key='$(cat ~/.ssh/k8s_ansible_new.pub)' state=present"

# Verify new key works
ansible all -i ansible/inventory/generated/hosts.yaml \
  --private-key ~/.ssh/k8s_ansible_new -m ping

# Remove old key
ansible all -i ansible/inventory/generated/hosts.yaml \
  --private-key ~/.ssh/k8s_ansible_new \
  -m ansible.posix.authorized_key \
  -a "user=ubuntu key='$(cat ~/.ssh/k8s_ansible.pub)' state=absent"
```
Update `ANSIBLE_SSH_PRIVATE_KEY` and `ANSIBLE_SSH_PUBLIC_KEY` in Forgejo Secrets.

---

### RUSTFS_ACCESS_KEY / RUSTFS_SECRET_KEY

**What they are:** S3-style access key ID and secret for the RustFS bucket
`terraform-state`.

**What they can do:** Read and write objects in the `terraform-state` bucket.
Anyone with these can read the `terraform.tfstate` file, which contains
**resource IDs and metadata but not secrets** (Terraform marks sensitive
variables and does not write them to state plaintext).

**Rotation:** Generate new credentials in the RustFS/TrueNAS admin panel,
update `RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY` in Forgejo, then revoke
the old credentials.

---

## What the state file contains

`terraform.tfstate` records the IDs, names, and configuration of every
Terraform-managed resource. For this setup that includes VM IDs, IP addresses,
MAC addresses, and disk sizes. It does **not** contain:

- The Proxmox API token
- The SSH private key
- RustFS credentials
- Passwords of any kind

Terraform marks variables declared as `sensitive = true` and avoids printing
them in plans and outputs, but the state file itself is not encrypted. If the
RustFS bucket were publicly accessible (it is not — it's on a private LAN),
the state would leak IP and VM topology information but not credentials.

For higher environments: consider adding state encryption. Terraform's
`encryption {}` block (added in 1.7) supports this natively.

---

## Audit: has a secret ever been committed?

Run this before sharing the repo or making it public:

```bash
# Check current working tree for common patterns
git grep -i "BEGIN OPENSSH PRIVATE KEY"
git grep -E "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
git grep -i "password\s*=\s*['\"]"

# Scan full git history (slow but thorough)
git log --all -p | grep -E "BEGIN .* PRIVATE KEY"
git log --all -p | grep -E "api_token\s*=\s*['\"]"
```

If a secret appears in history, treat it as compromised immediately. Rotate it
(see sections above), then optionally clean history with `git filter-repo`.
History rewriting is disruptive if others have cloned the repo; rotation is
always the priority.

---

## Pre-commit checklist (for contributors)

Before every `git commit`:

```bash
# Nothing sensitive in staged files?
git diff --cached | grep -iE "(password|private.key|api.token|secret)"

# No generated files accidentally staged?
git status | grep -E "(generated/|kubeconfig/|\.tfvars$)"

# terraform.tfvars is not staged?
git diff --cached --name-only | grep "terraform.tfvars$"
```

Or configure a local git hook — see `docs/contributing.md` (if present) for
the hook script.

---

## Network exposure

All sensitive components are LAN-only:

| Component | Address | LAN-only? |
|---|---|---|
| Proxmox API | `192.168.1.100:8006` | ✅ Yes |
| RustFS | `192.168.1.50:30293` | ✅ Yes |
| Forgejo | TrueNAS host | ✅ Yes |
| K8s API server | `192.168.1.201:6443` | ✅ Yes |
| K8s worker nodes | `192.168.1.202-203` | ✅ Yes |

No port forwarding to the internet. No public ingress (ingress-nginx is
currently disabled). This significantly reduces the attack surface — a
compromised secret can only be used from the same LAN segment.

---

## Checkpoint questions

1. If `PROXMOX_SSH_PRIVATE_KEY` were stolen, what could an attacker do? What could they NOT do?
2. What information is in `terraform.tfstate`? Is there a reason to keep it private?
3. You accidentally committed `terraform.tfvars` two commits ago. What are the two steps to take, in order?
4. Why is it safe to commit `.terraform.lock.hcl` but not `terraform.tfvars`?
5. Can you rotate `ANSIBLE_SSH_PRIVATE_KEY` without rebuilding the cluster? What's the procedure?

## Common mistakes

| Mistake | Consequence | Fix |
|---|---|---|
| Forgetting `--privsep 0` on new token | Token rotation "succeeds" but workflows 403 | Delete and recreate the token with the flag |
| Rotating key locally but not updating Forgejo secret | Next workflow run fails auth | Always update Forgejo Secrets immediately after key rotation |
| Using the same keypair for Proxmox and K8s VMs | One compromise reaches both layers | Keep keys split: `k8s_proxmox` for Proxmox, `k8s_ansible` for VMs |
| Committing `terraform.tfvars` | API token and private key in git history | Rotate credentials immediately; then optionally clean history |
| Leaving old key authorised after rotation | Two valid keys exist; old one is a risk | Always remove the old key after verifying the new one works |

---

*Previous: [Chapter 10 — Troubleshooting Labs](10-troubleshooting-labs.md) · Next: [Chapter 12 — Upgrades & Next Steps](12-upgrades-next-steps.md)*
