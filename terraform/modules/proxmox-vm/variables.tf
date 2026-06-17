# terraform/modules/proxmox-vm/variables.tf

variable "vm_name" {
  description = "VM display name in Proxmox"
  type        = string
}

variable "vm_id" {
  description = "Proxmox VM ID (must be unique per node)"
  type        = number
}

variable "node_name" {
  description = "Proxmox node name"
  type        = string
}

variable "template" {
  description = "Name of the cloud-init template to clone"
  type        = string
}

variable "cpu" {
  description = "Number of vCPUs"
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "RAM in MiB"
  type        = number
  default     = 4096
}

variable "disk_size" {
  description = "Root disk size in GiB"
  type        = number
  default     = 30
}

variable "ip_address" {
  description = "Static IPv4 address (without prefix length)"
  type        = string
}

variable "gateway" {
  description = "Default gateway"
  type        = string
}

variable "bridge" {
  description = "Proxmox bridge interface"
  type        = string
  default     = "vmbr0"
}

variable "ssh_public_key" {
  description = "SSH public key to inject via cloud-init"
  type        = string
  sensitive   = true
}

variable "disk_datastore" {
  description = "Proxmox datastore for the VM root disk (e.g. 'local-lvm', 'ceph-pool')"
  type        = string
  default     = "local-lvm"
}

variable "cidr_prefix" {
  description = "IPv4 prefix length for the VM's static address (e.g. 24 for /24)"
  type        = number
  default     = 24
}

variable "dns_servers" {
  description = "DNS servers injected via cloud-init"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "ssh_user" {
  description = "Username created by cloud-init and used by Ansible to SSH into the VM. Defaults to 'ubuntu' (matches the Ubuntu cloud image default). Change only if you use a custom base image with a different default user."
  type        = string
  default     = "ubuntu"
}
