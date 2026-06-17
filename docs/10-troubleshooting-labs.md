# Chapter 10 — Troubleshooting Labs

**Goal:** Be able to diagnose and fix common failures without help, using a
structured approach: observe → hypothesise → test → fix → verify.

**You will learn:** Root causes of every issue encountered during initial
deployment, how to read error messages, and the recovery procedure for each.

**Prerequisites:** [Chapter 09 — Operations Runbook](09-operations-runbook.md).
You should have a running cluster before attempting the break/fix exercises.
For intentional break/fix labs, see [appendix/failure-labs.md](appendix/failure-labs.md).

**Where to run commands:**

| Step | Run on |
|---|---|
| `kubectl` diagnostics | LXC-Rocky10 |
| `qm` / `pveum` commands | Proxmox host |
| `terraform state` | Runner LXC workspace |
| Ansible playbooks | Runner LXC (via workflow or manually) |
| SSH to nodes | LXC-Rocky10 or workstation |

---

## Diagnosis approach

Before jumping to fixes, always collect state first:

```bash
# 1. Are nodes up?
kubectl get nodes

# 2. Any non-Running pods?
kubectl get pods -A | grep -Ev 'Running|Completed'

# 3. Check events for the broken resource
kubectl describe <resource> <name> -n <namespace>

# 4. If a node is NotReady — SSH in and check kubelet
ssh -i ~/.ssh/k8s_ansible ubuntu@<node-ip>
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 50
```

Only after observing should you form a hypothesis and apply a fix.

---


## Terraform

### `proxmox_ssh_private_key` variable not declared

**Symptom**
```
Error: Reference to undeclared input variable
  on main.tf line 21, in provider "proxmox":
  21: private_key = var.proxmox_ssh_private_key
An input variable with the name "proxmox_ssh_private_key" has not been declared.
```

**Cause**  
The `ssh {}` block was added to `provider "proxmox"` in `envs/homelab/main.tf`
but the corresponding `variable "proxmox_ssh_private_key"` block was never added
to `envs/homelab/variables.tf`.

**Fix**  
Add to `terraform/envs/homelab/variables.tf`:

```hcl
variable "proxmox_ssh_private_key" {
  description = "SSH private key for bpg/proxmox provider to connect to the Proxmox host"
  type        = string
  sensitive   = true
}
```

The workflow already passes `TF_VAR_proxmox_ssh_private_key` from
`PROXMOX_SSH_PRIVATE_KEY` — the variable declaration was simply missing.

---

### `generated/` directory missing during output export

**Symptom**
```
/home/forgejo-runner/.cache/act/.../hostexecutor/ansible/inventory/generated/terraform-output.json:
No such file or directory
```

Occurred in both `terraform-apply.yml` (Export Terraform outputs step) and
`ansible-deploy.yml` (Extract Terraform output step).

**Cause**  
`ansible/inventory/generated/` is `.gitignored` and therefore never exists in
a fresh checkout. The `terraform output -json >` redirect fails immediately
when the parent directory is missing.

**Fix**  
Add `mkdir -p` before the redirect in both workflows:

In `terraform-apply.yml`:
```yaml
run: |
  mkdir -p $GITHUB_WORKSPACE/ansible/inventory/generated
  terraform output -json > \
    $GITHUB_WORKSPACE/ansible/inventory/generated/terraform-output.json
```

In `ansible-deploy.yml`:
```yaml
run: |
  mkdir -p "$GITHUB_WORKSPACE/ansible/inventory/generated"
  terraform init -reconfigure -input=false -no-color
  terraform output -json > \
    "$GITHUB_WORKSPACE/ansible/inventory/generated/terraform-output.json"
```

---

### Terraform apply killed by job timeout mid-VM-creation

**Symptom**
```
module.k8s_cp_01.proxmox_virtual_environment_vm.vm: Still creating... [14m40s elapsed]
ctx: context deadline exceeded, exec: RUN signal: killed
```

**Cause**  
The job `timeout-minutes` was set to `30`. Cloning three VMs from a template
(especially with 40 GB disks on LVM) takes 20–30 minutes. The timeout was hit
before all VMs finished creating.

**Fix**  
Increase timeout in `terraform-apply.yml`:
```yaml
jobs:
  apply:
    runs-on: [proxmox-infra]
    timeout-minutes: 60
```

**Recovery**  
After a killed apply, some VMs may be in a partial state in both Proxmox and
Terraform state. Before re-running:

1. On the Proxmox host, check for orphaned VMs:
   ```bash
   qm list
   ```
2. Destroy any partially created cluster VMs (201, 202, 203) that exist but are broken:
   ```bash
   qm stop 201 --skiplock 2>/dev/null || true
   qm destroy 201 --destroy-unreferenced-disks 1 --purge 1
   ```
3. Remove them from Terraform state:
   ```bash
   terraform state rm module.k8s_cp_01.proxmox_virtual_environment_vm.vm
   terraform state rm module.k8s_worker_01.proxmox_virtual_environment_vm.vm
   terraform state rm module.k8s_worker_02.proxmox_virtual_environment_vm.vm
   ```
4. Leave `module.ubuntu_template` in state — the image and template VM are fine.
5. Re-trigger the apply.

---

### Partial apply leaves broken template VM (ID 9000) in Proxmox

**Symptom**  
A previous apply failed during template VM creation. The next apply fails
because VM ID 9000 already exists in Proxmox but is in an inconsistent state,
or exists in Terraform state but not in Proxmox.

**Fix**  
On the Proxmox host:
```bash
qm stop 9000 --skiplock 2>/dev/null || true
qm destroy 9000 --destroy-unreferenced-disks 1 --purge 1
```

Then remove from Terraform state:
```bash
terraform state rm module.ubuntu_template.proxmox_virtual_environment_vm.template
terraform state rm module.ubuntu_template.proxmox_virtual_environment_download_file.ubuntu_cloud_image
```

The cloud image file at `/var/lib/vz/template/iso/ubuntu-24.04-cloud.img` can
be left alone — `overwrite = false` in the download resource means Terraform
will skip re-downloading if the file already exists with a matching checksum.

---

## Ansible / post-k8s.yml

### `sudo: a password is required` on localhost-delegated tasks

**Symptom**
```
TASK [Ensure local kubeconfig directory exists]
fatal: [k8s-cp-01 -> localhost]: FAILED! => changed=false
  msg: MODULE FAILURE
  module_stderr: sudo: a password is required
```

**Cause**  
`ansible.cfg` has `become = true` globally in `[privilege_escalation]`, and
`group_vars/all/all.yml` has `ansible_become: true`. Tasks delegated to
`localhost` (the runner LXC) inherit this and try to `sudo` on the runner.
The `forgejo-runner` user has no passwordless sudo configured.

**Fix**  
Add `become: false` at the play level in `ansible/playbooks/post-k8s.yml`.
This overrides the global setting for the entire play without touching
`ansible.cfg` or group_vars (which need `become: true` for the actual K8s
nodes):

```yaml
- name: Post-install cluster validation
  hosts: kube_control_plane[0]
  gather_facts: false
  become: false        # ← overrides global become=true for this play
```

Tasks that need to run as root on the remote control plane node (like copying
`admin.conf`) get `become: true` individually on those tasks only.

---

### `file is not readable: /etc/kubernetes/admin.conf`

**Symptom**
```
TASK [Fetch kubeconfig from control plane]
fatal: [k8s-cp-01]: FAILED! => changed=false
  msg: 'file is not readable: /etc/kubernetes/admin.conf'
```

**Cause**  
`/etc/kubernetes/admin.conf` is owned by root with mode `0600`. The Ansible
connection user is `ubuntu`. After adding `become: false` at the play level
(to fix the sudo issue above), `become: true` on the fetch task alone was
not reliably honoured in all Ansible versions when the play-level override
is present.

**Fix**  
Don't fight the file permissions on the fetch. Instead, copy the file to a
world-readable temporary location as root, fetch from there, then remove it:

```yaml
- name: Copy kubeconfig to readable temp location
  ansible.builtin.copy:
    src: /etc/kubernetes/admin.conf
    dest: /tmp/admin.conf
    mode: "0644"
    remote_src: true
  become: true

- name: Fetch kubeconfig from control plane
  ansible.builtin.fetch:
    src: /tmp/admin.conf
    dest: "{{ kubeconfig_local_path }}"
    flat: true

- name: Remove temp kubeconfig copy
  ansible.builtin.file:
    path: /tmp/admin.conf
    state: absent
  become: true
```

The `copy` and `file` (remove) tasks run as root on the remote CP — `become: true`
works correctly there because the `ubuntu` user has passwordless sudo on
Kubespray-provisioned nodes. The fetch reads `/tmp/admin.conf` which is
world-readable, requiring no privilege.

---

## Ansible — deprecation warning

**Symptom**
```
[DEPRECATION WARNING]: [defaults]collections_paths option, does not fit var
naming standard, use the singular form collections_path instead. This feature
will be removed from ansible-core in version 2.19.
```

**Cause**  
`ansible/ansible.cfg` uses the old plural key name `collections_paths`.

**Fix**  
In `ansible/ansible.cfg`, rename:
```ini
# Before
collections_paths  = ~/.ansible/collections

# After
collections_path   = ~/.ansible/collections
```

Not urgent (warning only, not an error), but fix before upgrading to
ansible-core 2.19 where it becomes a hard failure.

---

## Runner registration

### Runner config uses old `register` CLI flow

Forgejo 15 changed runner registration to a config-file flow. The old
`forgejo-runner register --no-interactive` flags no longer work.

**Correct flow for Forgejo 15:**

1. Generate base config: `forgejo-runner generate-config > runner-config.yml`
2. Edit `runner-config.yml` to set label, UUID, token, and workdir
3. Get UUID and token from Forgejo UI: **Repository → Settings → Actions → Runners → Create new runner**
4. The token is shown **once only** — copy it before closing the dialog
5. Start the daemon: `forgejo-runner daemon -c runner-config.yml`

See [Chapter 05 — Forgejo Runner](05-forgejo-runner.md) for the full config file template.

---

### Runner label must include `:host` suffix

**Symptom**  
Workflows sit in "Waiting" state indefinitely and never get picked up by the runner.

**Cause**  
The runner label in `runner-config.yml` was set to just `proxmox-infra` without
the `:host` type suffix. Forgejo label syntax is `<name>:<type>` where valid
types are `docker`, `lxc`, and `host`. Without `:host`, the runner does not
declare an execution type and may not match `runs-on: [proxmox-infra]`.

**Fix**  
```yaml
runner:
  labels:
    - "proxmox-infra:host"
```

---

## `.terraform.lock.hcl`

### Lock file not committed

**Symptom**  
`terraform init` re-downloads the provider on every run (slower), or picks up
a different provider version than expected.

**Cause**  
`.gitignore` was blocking `.terraform.lock.hcl` from being committed, or the
file was never copied from the runner workspace back to the repo.

**Fix**  
After the first successful `terraform init`, the lock file is generated in
`terraform/envs/homelab/.terraform.lock.hcl`. Commit it:

```bash
git add terraform/envs/homelab/.terraform.lock.hcl
git commit -m "chore: commit terraform provider lock file"
```

Verify `.gitignore` does not have a rule blocking it. The correct gitignore
pattern excludes the `.terraform/` directory (cache) but not the lock file:

```gitignore
**/.terraform/          # correct — excludes provider cache
# .terraform.lock.hcl  # do NOT ignore this
```

---

## Terraform / terraform-apply.yml

### QEMU agent timeout warning after VM creation

**Symptom**

After all three VMs are created, the Terraform log shows:

```
Warning: error waiting for network interfaces from QEMU agent
  timeout while waiting for the QEMU agent on VM "202" to publish
  the network interfaces
(and 2 more similar warnings elsewhere)
```

This appears on one or more VMs, but `Apply complete!` still follows.

**Cause**

The `bpg/proxmox` provider waits for the QEMU guest agent inside each VM to
report its network interfaces after boot. The agent only starts after
cloud-init finishes, which takes 30–90 seconds on a fresh clone. If the
provider's wait window expires before the agent is ready, it logs this
warning and continues anyway — the VM is not affected.

**This is harmless** if:
- `Apply complete! Resources: N added` appears after the warnings
- All three VMs show as running in the Proxmox UI
- The VMs respond to ping within a few minutes

**This is a real problem** if:
- The apply ends with `Error:` instead of `Apply complete!`
- A VM does not start (check Proxmox UI → VM → Summary → Status)
- SSH to the VM fails after 5 minutes (check cloud-init via `qm terminal 201`)

**Fix (if the warning is benign)**

No action needed. Proceed to the Ansible deploy step.

**Fix (if the VM is genuinely not reachable)**

Check the Proxmox console directly:

```bash
# On the Proxmox host
qm terminal 201
# Login as ubuntu, then:
cloud-init status
ip a
```

If cloud-init shows an error or the IP is wrong, the issue is in the
cloud-init configuration (gateway, IP, or SSH key injection), not the QEMU
agent.

---

### Deprecated resource warning: `proxmox_virtual_environment_download_file`

**Symptom**

```
Warning: Deprecated
  Use "proxmox_download_file" instead.
  This resource / data source will be removed in v1.0.
```

**Cause**

The `bpg/proxmox` provider renamed `proxmox_virtual_environment_download_file`
to `proxmox_download_file` in preparation for v1.0. The module still uses the
old name.

**Action**

Ignore while the provider is pinned to `~> 0.109.0`. When upgrading the
provider to v1.0, update `terraform/modules/proxmox-template/main.tf` to use
`proxmox_download_file` instead.

---

*Previous: [Chapter 09 — Operations Runbook](09-operations-runbook.md) · Next: [Chapter 11 — Security & Key Rotation](11-security-key-rotation.md)*

---

## Ansible / pre-k8s.yml

### `cloud-init status --wait` exits with rc=2 despite `status: done`

**Symptom**
```
TASK [Wait for cloud-init to finish]
fatal: [k8s-cp-01]: FAILED! => changed=false
  cmd:
  - cloud-init
  - status
  - --wait
  msg: non-zero return code
  rc: 2
  stdout: 'status: done'
```

**Cause**  
Cloud-init 23.4+ (Ubuntu 24.04) has three exit codes:

| rc | Meaning |
|---|---|
| 0 | Finished successfully |
| 1 | Unrecoverable crash — cloud-init did not complete |
| 2 | Finished with recoverable errors (warnings only) |

`status: done` in stdout confirms cloud-init completed. `rc: 2` is normal on
fresh Proxmox-provisioned Ubuntu 24.04 VMs; it reflects warnings during
network or datasource setup, not a failure. The task was too strict.

**Fix** (already in the repo — no action needed if you have the latest code)

`ansible/playbooks/pre-k8s.yml`:
```yaml
- name: Wait for cloud-init to finish
  ansible.builtin.command: cloud-init status --wait --long
  register: cloud_init_status
  changed_when: false
  failed_when: >-
    cloud_init_status.rc not in [0, 2]
    or 'status: done' not in cloud_init_status.stdout

- name: Show cloud-init output (printed when rc=2 recoverable errors occurred)
  ansible.builtin.debug:
    var: cloud_init_status.stdout_lines
  when: cloud_init_status.rc == 2
```

The `--long` flag adds module-level detail to stdout, so when `rc: 2` fires
the debug task shows exactly what warning cloud-init raised.

**Verify the fix worked**: after re-triggering `ansible-deploy`, the task
should show `ok` instead of `fatal`, and the debug task will print the
cloud-init warning lines (if any) so you can see what caused `rc: 2`.

---

## Ansible / Kubespray

### Kubespray stops mid-run without a final PLAY RECAP

**Symptom**

The Kubespray step stops during image download or container setup. The log does
not show a normal Ansible `fatal` error and does not end with a final Kubespray
`PLAY RECAP`. The Forgejo job either hangs indefinitely or ends with a generic
runner error rather than an Ansible failure.

**Likely cause**

The Forgejo runner stopped, crashed, or was restarted while the job was in
progress. This is distinct from an Ansible task failure — there is no Ansible
error because Ansible never got the chance to report one.

Common triggers: runner LXC ran out of memory mid-Kubespray, Proxmox host
rebooted, or the runner service was manually restarted.

**Diagnose**

On the runner LXC:

```bash
systemctl status forgejo-runner
journalctl -u forgejo-runner -n 100
```

Look for lines like `runner exited`, `OOM`, or a timestamp gap that matches
when the job stopped.

**Fix**

```bash
systemctl restart forgejo-runner
systemctl status forgejo-runner
```

Then re-trigger the `Ansible — Deploy K8s Cluster` workflow from Forgejo.

If the previous run had already downloaded container images or binaries onto
the nodes, the next run may be faster — Kubespray checks for existing
installation state before re-downloading.

**How to tell this apart from a normal Ansible failure**

| Symptom | Cause |
|---|---|
| Log ends with `PLAY RECAP ... failed=1` | Ansible task failed — read the `fatal:` lines above the recap |
| Log ends with `fatal:` but no PLAY RECAP | Ansible hit an unrecoverable error (e.g. SSH unreachable) |
| Log stops mid-task, no fatal, no recap | Runner died — restart the runner and rerun |
| Forgejo shows job as "Cancelled" | Job was manually cancelled or timed out — check `timeout-minutes` in the workflow |

---

*Previous: [Chapter 09 — Operations Runbook](09-operations-runbook.md) · Next: [Chapter 11 — Security & Key Rotation](11-security-key-rotation.md)*
