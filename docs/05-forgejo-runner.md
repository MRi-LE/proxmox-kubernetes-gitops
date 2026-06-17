# Chapter 05 — Forgejo Runner

**Goal:** Have the `proxmox-infra` runner LXC online, registered in Forgejo,
and confirmed able to pick up a workflow job.

**You will learn:** How Forgejo Actions runners work, why we use a host executor
instead of Docker, how to register a runner in Forgejo 15's config-file flow,
and how to verify the runner is healthy.

**Prerequisites:** [Chapter 04 — RustFS State Backend](04-rustfs-state-backend.md).

**Where to run commands:**

| Step | Run on | User |
|---|---|---|
| Install packages | Runner LXC | `root` |
| Create `forgejo-runner` user | Runner LXC | `root` |
| Install runner binary | Runner LXC | `root` |
| Generate config, edit label | Runner LXC | `forgejo-runner` (switch with `su -`) |
| Create runner in Forgejo | Forgejo web UI | repo admin |
| Add UUID/token to config | Runner LXC | `forgejo-runner` |
| Create and start systemd service | Runner LXC | `root` |
| Verify network reachability | Runner LXC | `root` or `forgejo-runner` |

---

This document covers provisioning and registering the dedicated CI runner that
executes all three workflows (`terraform-plan`, `terraform-apply`,
`ansible-deploy`). The runner is an LXC container on Proxmox using a **host
(shell) executor** — no Docker, no nesting required.

> **Security note:** Host runners execute jobs directly on the LXC filesystem
> with no container or sandbox isolation between runs. Only use this runner for
> trusted repositories. For `k8s-infra` this is acceptable — it is a
> single-operator, private repository.

---

## 1. Create the LXC on Proxmox

In the Proxmox web UI: **Create CT**

| Field | Value |
|---|---|
| Hostname | `forgejo-runner-infra` |
| Template | Debian 12 Bookworm or Ubuntu 24.04 |
| vCPU | 2 |
| RAM | 2048 MB |
| Disk | 20 GB on `local-lvm` |
| Network | `vmbr0`, static IP on your LAN (e.g. `192.168.1.210`) |
| Unprivileged | ✅ Yes |
| Nesting | Not required — jobs run directly on the LXC host via the `host` executor, not inside a nested container |

Start the container after creation.

---

## 2. Install Required Tools

SSH into the LXC and run the following as root.

### System packages

```bash
apt update && apt upgrade -y

apt install -y \
  ca-certificates \
  curl \
  wget \
  git \
  unzip \
  gnupg \
  lsb-release \
  jq \
  openssh-client \
  python3 \
  python3-pip \
  python3-venv \
  sudo \
  nano
```

### Node.js

Node.js is required on the runner LXC because common Forgejo/GitHub-compatible
actions — including `actions/checkout` — are JavaScript actions. When a workflow
step uses `uses: actions/checkout@v4`, the runner downloads the action and
executes it with Node.js directly on the host. Without Node.js present, every
`uses:` step will fail.

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs

node --version    # expect v22.x
npm --version
```

### Terraform ≥ 1.6

```bash
wget -O- https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/hashicorp.list

apt update && apt install -y terraform
terraform version   # must be ≥ 1.6
```

### kubectl

```bash
cd /tmp

curl -LO "https://dl.k8s.io/release/$(curl -Ls \
  https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

curl -LO "https://dl.k8s.io/release/$(curl -Ls \
  https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"

echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check

install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

### Python venv check

The workflows create a `.venv` at runtime inside the job workspace — the runner
only needs a working `python3 -m venv`. No system-level Ansible install is
needed or wanted; `ansible-deploy.yml` installs all Python dependencies into
the venv using `ansible/requirements.txt`.

```bash
python3 -m venv /tmp/test-venv && echo "venv ok" && rm -rf /tmp/test-venv
```

---

## 3. Create a Dedicated Runner User

```bash
useradd -m -s /bin/bash forgejo-runner
```

All runner operations (config, daemon, job workspace) run under this user.
The runner binary itself is installed to `/usr/local/bin` (root-owned,
world-executable) and called by the systemd service as this user.

---

## 4. Install the Forgejo Runner Binary

The runner binary is released separately from Forgejo itself. Fetch the latest
release version from the Forgejo API and download the correct architecture:

```bash
cd /tmp

ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
RUNNER_VERSION=$(curl -s \
  https://data.forgejo.org/api/v1/repos/forgejo/runner/releases/latest \
  | jq -r .name | cut -c 2-)

wget -O forgejo-runner \
  "https://code.forgejo.org/forgejo/runner/releases/download/v${RUNNER_VERSION}/forgejo-runner-${RUNNER_VERSION}-linux-${ARCH}"

install -o root -g root -m 0755 forgejo-runner /usr/local/bin/forgejo-runner
forgejo-runner --version
```

---

## 5. Register the Runner

Forgejo 15 uses a **config-file registration flow**, not the older
`register --no-interactive` CLI flags. The steps are:

### 5a. Generate the base config

Switch to the runner user and generate the default config:

```bash
su - forgejo-runner

forgejo-runner generate-config > /home/forgejo-runner/runner-config.yml
nano /home/forgejo-runner/runner-config.yml
```

### 5b. Set the runner label

Find the `runner:` section in the config and set the label to
`proxmox-infra:host`. The `:host` suffix tells Forgejo this runner uses the
host executor — it is what makes `runs-on: [proxmox-infra]` in your workflows
match this runner.

```yaml
runner:
  labels:
    - "proxmox-infra:host"
```

> Without `:host`, the label does not explicitly define an execution type.
> Forgejo label syntax is `<name>:<type>` where valid types are `docker`, `lxc`,
> and `host`. For this runner we want no containerization, so the correct label
> is `proxmox-infra:host`.

### 5c. Create the runner in Forgejo

In the Forgejo web UI, navigate to:

**Repository → Settings → Actions → Runners → Create new runner**

Use a **repository-scoped** runner (not the global admin runner) — it will only
pick up jobs from `k8s-infra`, which is exactly what you want.

Set:
- **Name:** `proxmox-infra`
- **Description:** `Dedicated IaC runner for Terraform / Kubespray`

After clicking Create, Forgejo displays a **UUID** and **token**. Copy both —
the token is shown only once.

### 5d. Add the UUID, token, and workdir to the config

Back in `runner-config.yml`, find or add the `server:` and `host:` sections:

```yaml
server:
  connections:
    forgejo:
      url: "https://<your-forgejo-host>/"
      uuid: "<uuid-from-forgejo>"
      token: "<token-from-forgejo>"

host:
  workdir_parent: /home/forgejo-runner/work
```

Setting `workdir_parent` explicitly avoids the default of `$HOME/.cache/act/`,
which is easy to overlook when troubleshooting or manually cleaning up between
runs. All job workspaces will be created as subdirectories under
`/home/forgejo-runner/work/`.

Save the file, then exit back to root:

```bash
exit
```

---

## 6. Run as a systemd Service

As root, create the service unit:

```bash
cat > /etc/systemd/system/forgejo-runner.service << 'EOF'
[Unit]
Description=Forgejo Runner (proxmox-infra)
After=network-online.target
Wants=network-online.target

[Service]
User=forgejo-runner
Group=forgejo-runner
WorkingDirectory=/home/forgejo-runner
Environment=HOME=/home/forgejo-runner
ExecStart=/usr/local/bin/forgejo-runner daemon -c /home/forgejo-runner/runner-config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create the workdir and lock down the config file before starting the service
mkdir -p /home/forgejo-runner/work
chown -R forgejo-runner:forgejo-runner /home/forgejo-runner/work
chown forgejo-runner:forgejo-runner /home/forgejo-runner/runner-config.yml
chmod 600 /home/forgejo-runner/runner-config.yml

systemctl daemon-reload
systemctl enable --now forgejo-runner
systemctl status forgejo-runner --no-pager
```

Check the logs to confirm it connected:

```bash
journalctl -u forgejo-runner -n 100 --no-pager
```

A successful connection looks like:

```
level=info msg="runner: connected to Forgejo"
level=info msg="runner: waiting for jobs"
```

---

## 7. Verify Registration

In the Forgejo web UI: **Repository → Settings → Actions → Runners**

The `proxmox-infra` runner should appear with status **Online** and label
`proxmox-infra`.

---

## 8. Workspace Behaviour (Host Executor)

With the host executor, Forgejo runner checks out the repo into a workspace
directory under the runner user's home on each job. The workspace is **not**
automatically cleaned between runs — this is a deliberate tradeoff for speed,
but it means reruns can hit leftover state. This is why the workflows are
written defensively:

| Workflow | Defensive measure |
|---|---|
| `ansible-deploy.yml` | `rm -rf ansible/kubespray` before cloning |
| `ansible-deploy.yml` | Cleanup step (`always:`) removes `~/.ssh/k8s_ansible` and generated inventory |
| All workflows | `terraform init -reconfigure` forces backend re-init regardless of cached state |

To manually wipe the workspace if needed:

```bash
# As forgejo-runner user
rm -rf /home/forgejo-runner/work/*
```

---

## 9. Pre-flight Checklist

### Tools

- [ ] LXC created, started, and reachable over SSH
- [ ] `node --version` shows v22.x
- [ ] `terraform version` shows ≥ 1.6
- [ ] `kubectl version --client` succeeds
- [ ] `python3 -m venv /tmp/t && rm -rf /tmp/t` succeeds
- [ ] `forgejo-runner --version` succeeds

### Runner config and service

- [ ] `runner-config.yml` has label `proxmox-infra:host`, correct UUID/token, and `host.workdir_parent` set
- [ ] `systemctl status forgejo-runner` shows `active (running)`
- [ ] Logs show `connected to Forgejo` and `waiting for jobs`
- [ ] Runner appears **Online** in repository Settings → Actions → Runners

### Network reachability

Run these from inside the LXC before triggering any workflow. The Proxmox and
RustFS checks do not need to authenticate — they just confirm the runner can
reach each internal service.

```bash
# Forgejo
curl -I https://<your-forgejo-host>/

# Proxmox API
curl -k https://192.168.1.100:8006/api2/json/version

# RustFS / S3 backend
curl -I http://192.168.1.50:30293

# Future Kubernetes node IPs (will be unreachable until VMs are provisioned —
# run again after terraform-apply to confirm)
ping -c 2 192.168.1.201
ping -c 2 192.168.1.202
ping -c 2 192.168.1.203
```

### Final

- [ ] Test PR triggers `terraform-plan.yml` and runner picks it up

---

## Checkpoint questions

1. Why does Node.js need to be installed on the runner LXC?
2. What does the `:host` suffix on the label `proxmox-infra:host` tell Forgejo?
3. A workflow `runs-on: [proxmox-infra]` but the job stays "Waiting". Name three things to check in order.
4. Why is `workdir_parent` set explicitly in `runner-config.yml`? What is the default?
5. The runner registers successfully but goes offline immediately. What is the most likely cause and how do you diagnose it?

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Label set to `proxmox-infra` without `:host` | Runner registers but jobs fail to start | Edit `runner-config.yml`, restart service |
| Runner registered as global (admin) instead of repository-scoped | Runner picks up jobs from other repos | Delete and recreate as repo-scoped runner |
| Node.js not installed | Every `uses: actions/checkout@v4` step fails with "executable not found" | `apt install nodejs` (via nodesource) |
| `runner-config.yml` has wrong UUID or token | Runner logs show auth errors, never connects | Re-check UUID and token from Forgejo UI |
| Service started before `workdir_parent` directory created | First job fails with workspace permission error | `mkdir -p /home/forgejo-runner/work && chown forgejo-runner:forgejo-runner /home/forgejo-runner/work` |

---

*Previous: [Chapter 04 — RustFS State Backend](04-rustfs-state-backend.md) · Next: [Chapter 06 — Terraform VMs](06-terraform-vms.md)*
