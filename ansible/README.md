# Ansible — K8s Cluster Installation

Installs a Kubernetes cluster on the VMs provisioned by Terraform, using
[Kubespray](https://github.com/kubernetes-sigs/kubespray) as the underlying
installer.

## Structure

```
ansible/
├── ansible.cfg                      # project-local config (auto-detected)
├── requirements.txt                 # pip deps
├── requirements.yml                 # Galaxy collections
├── kubespray/                       # cloned at runtime — NOT in git
├── inventory/
│   ├── generated/                   # .gitignored — built from TF output at runtime
│   ├── group_vars/all/
│   │   ├── all.yml                  # SSH / become / timeouts
│   │   └── kubespray.yml            # CNI, K8s version, addons
│   └── host_vars/                   # per-host overrides (empty)
├── playbooks/
│   ├── pre-k8s.yml                  # OS prep: hostname, swap, sysctl, kernel modules
│   └── post-k8s.yml                 # fetch kubeconfig, patch server URL, verify nodes
└── scripts/
    └── generate_inventory.py        # TF JSON → Kubespray hosts.yaml
```

Kubespray is **not** stored as a git submodule. It is cloned at pipeline runtime
(and locally on demand) to avoid git submodule complexity on Windows (GitHub Desktop).

## First-time local setup

```bash
# 1. Clone Kubespray manually (the CI pipeline does this automatically)
git clone --branch v2.26.0 --depth 1 \
  https://github.com/kubernetes-sigs/kubespray.git \
  ansible/kubespray

# 2. Create venv and install dependencies
python3 -m venv .venv && source .venv/bin/activate
pip install -r ansible/requirements.txt
pip install -r ansible/kubespray/requirements.txt

# 3. Install Galaxy collections
ansible-galaxy collection install -r ansible/requirements.yml
ansible-galaxy collection install -r ansible/kubespray/requirements.yml

# 4. Generate inventory (after terraform apply)
mkdir -p ansible/inventory/generated
cd terraform/envs/homelab
terraform output -json > ../../../ansible/inventory/generated/terraform-output.json
cd ../../..
python3 ansible/scripts/generate_inventory.py \
    --tf-output ansible/inventory/generated/terraform-output.json \
    --out       ansible/inventory/generated/hosts.yaml

# 5. Run playbooks in order
ansible-playbook -i ansible/inventory/generated/hosts.yaml \
    --private-key ~/.ssh/k8s_ansible ansible/playbooks/pre-k8s.yml

ansible-playbook -i ansible/inventory/generated/hosts.yaml \
    --private-key ~/.ssh/k8s_ansible \
    --extra-vars "supplementary_addresses_in_ssl_keys=['<CP_IP>']" \
    ansible/kubespray/cluster.yml

ansible-playbook -i ansible/inventory/generated/hosts.yaml \
    --private-key ~/.ssh/k8s_ansible ansible/playbooks/post-k8s.yml

# 6. Use the cluster
export KUBECONFIG=kubeconfig/homelab.yaml
kubectl get nodes
```

Replace `<CP_IP>` with `192.168.1.201` (or the value of `TF_VAR_CP01_IP`).

## Upgrading Kubespray / Kubernetes

1. Update the `--branch` tag in `.forgejo/workflows/ansible-deploy.yml`
2. Update `kube_version` in `ansible/inventory/group_vars/all/kubespray.yml`
3. Test with `kubespray_tags` input first (e.g. `upgrade`) before a full reinstall

## ansible.cfg notes

The project `ansible.cfg` is picked up automatically when running `ansible-*`
commands from the repo root (via `ANSIBLE_CONFIG=ansible/ansible.cfg` in CI,
or by Ansible's config-file search order locally).

Key settings:
- `collections_path` — uses the singular form required by ansible-core ≥ 2.15
- `host_key_checking = false` — safe for a private homelab; avoids SSH
  known-hosts friction on freshly provisioned VMs
- `stdout_callback = yaml` — more readable output than the default `minimal`
