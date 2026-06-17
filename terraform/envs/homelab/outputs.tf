# terraform/envs/homelab/outputs.tf
#
# These outputs are the contract between Terraform and Ansible.
# Keys consumed by ansible/scripts/generate_inventory.py are marked [inventory].
# Do not rename [inventory] keys without updating generate_inventory.py.

# ── Inventory outputs — consumed by generate_inventory.py ────────────────────

output "vm_ips" {
  description = "[inventory] Map of VM name → static IP. Used to populate ansible_host, ip, and access_ip in hosts.yaml."
  value = {
    "k8s-cp-01"     = module.k8s_cp_01.ip_address
    "k8s-worker-01" = module.k8s_worker_01.ip_address
    "k8s-worker-02" = module.k8s_worker_02.ip_address
  }
}

output "control_planes" {
  description = "[inventory] VM names assigned the kube_control_plane and etcd roles in hosts.yaml."
  value       = ["k8s-cp-01"]
}

output "workers" {
  description = "[inventory] VM names assigned the kube_node role in hosts.yaml."
  value       = ["k8s-worker-01", "k8s-worker-02"]
}

output "ansible_ssh_user" {
  description = "[inventory] Username created by cloud-init on all VMs. Written into hosts.yaml as ansible_user. Defaults to 'ubuntu' (Ubuntu cloud image default). Change the proxmox-vm module's ssh_user variable if you use a different base image."
  value       = module.k8s_cp_01.ssh_user
}

# ── Informational outputs — not consumed by generate_inventory.py ─────────────

output "vm_names" {
  description = "All VM names in the cluster. Informational — not read by generate_inventory.py (which derives names from vm_ips keys)."
  value       = ["k8s-cp-01", "k8s-worker-01", "k8s-worker-02"]
}

output "control_plane_ip" {
  description = "IP of the single control plane VM. Informational shorthand — used by post-k8s.yml to patch the kubeconfig server URL and by docs for SSH examples."
  value       = module.k8s_cp_01.ip_address
}

output "template_name" {
  description = "Name of the Proxmox template Terraform created. Informational — the proxmox-vm modules consume this internally via module.ubuntu_template.template_name; it does not need to be passed back in via tfvars."
  value       = module.ubuntu_template.template_name
}

output "template_vm_id" {
  description = "Proxmox VM ID reserved for the template (default 9000). Informational — useful when checking Proxmox UI or freeing the ID."
  value       = module.ubuntu_template.template_vm_id
}
