# terraform/envs/homelab/variables.tf

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint. Required. Example: https://192.168.0.10:8006"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token, e.g. terraform@pam!ci=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name (check Proxmox UI — commonly 'pve')"
  type        = string
  default     = "proxmox"
}

# ── Template — managed by Terraform, no longer a manual input ─────────────────
# These have sensible defaults; override in terraform.tfvars only if needed.
variable "template_name" {
  description = "Name for the Ubuntu cloud-init template VM Terraform will create"
  type        = string
  default     = "ubuntu-24.04-cloud"
}

variable "template_vm_id" {
  description = "Proxmox VM ID reserved for the template (must not clash with VM IDs below)"
  type        = number
  default     = 9000
}

variable "ansible_ssh_public_key" {
  description = "SSH public key injected into K8s VMs via cloud-init (Ansible deploy key — NOT the Proxmox key)"
  type        = string
  sensitive   = true
}

# ── Networking ─────────────────────────────────────────────────────────────────
# All four network variables are required — no defaults are provided because
# they are specific to your LAN. Set them in terraform.tfvars (local runs)
# or via Forgejo Variables TF_VAR_NETWORK_GATEWAY / TF_VAR_NETWORK_BRIDGE /
# TF_VAR_CP01_IP / TF_VAR_WORKER01_IP / TF_VAR_WORKER02_IP (CI runs).

variable "network_gateway" {
  description = "Default gateway for VM static IPs. Required. Example: 192.168.1.1"
  type        = string
}

variable "network_bridge" {
  description = "Proxmox bridge interface. Required. Check Proxmox UI → Network. Example: vmbr0"
  type        = string
}

variable "cp01_ip" {
  description = "Static IP for k8s-cp-01. Required. Must be free on your LAN. Example: 192.168.1.201"
  type        = string
}

variable "worker01_ip" {
  description = "Static IP for k8s-worker-01. Required. Must be free on your LAN. Example: 192.168.1.202"
  type        = string
}

variable "worker02_ip" {
  description = "Static IP for k8s-worker-02. Required. Must be free on your LAN. Example: 192.168.1.203"
  type        = string
}

variable "proxmox_ssh_private_key" {
  description = "SSH private key for bpg/proxmox provider → Proxmox host only. NEVER injected into K8s VMs."
  type        = string
  sensitive   = true
}

# ── Storage datastores ─────────────────────────────────────────────────────────
# Proxmox datastore names vary between installations.
# Common values: local-lvm (default LVM thin), ceph-pool, ssd-pool, data
# Check yours in: Proxmox UI → Datacenter → Storage
variable "disk_datastore" {
  description = "Proxmox datastore for all VM and template root disks (e.g. 'local-lvm', 'ceph-pool')"
  type        = string
  default     = "local-lvm"
}

variable "image_datastore" {
  description = "Proxmox datastore to download the Ubuntu cloud image into. Must accept 'iso' content (e.g. 'local', 'nas')"
  type        = string
  default     = "local"
}

# ── TLS ───────────────────────────────────────────────────────────────────────
# Set to false only if Proxmox has a valid, trusted TLS certificate.
# Self-signed certificates (the Proxmox default) require insecure = true.
variable "proxmox_tls_insecure" {
  description = "Skip TLS certificate verification for the Proxmox API. Set false only if you have a valid cert."
  type        = bool
  default     = true
}
