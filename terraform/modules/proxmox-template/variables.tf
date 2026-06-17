# terraform/modules/proxmox-template/variables.tf

variable "node_name" {
  description = "Proxmox node name"
  type        = string
}

variable "template_name" {
  description = "Name for the template VM (used by proxmox-vm modules to find it)"
  type        = string
  default     = "ubuntu-24.04-cloud"
}

variable "template_vm_id" {
  description = "Proxmox VM ID reserved for the template (must not clash with cluster VMs)"
  type        = number
  default     = 9000
}

variable "ubuntu_image_url" {
  description = "Direct URL to the Ubuntu 24.04 cloud image"
  type        = string
  # Noble Numbat (24.04 LTS) — pinned to the release path, not noble/current,
  # so the URL is stable and the checksum stays valid long-term.
  # Browse available releases: https://cloud-images.ubuntu.com/releases/24.04/release/
  default = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "ubuntu_image_checksum" {
  description = "SHA-256 checksum of the cloud image for integrity verification"
  type        = string
  # Verify / regenerate when you change ubuntu_image_url:
  #   curl -L https://cloud-images.ubuntu.com/releases/24.04/release/SHA256SUMS \
  #     | grep ubuntu-24.04-server-cloudimg-amd64.img
  default = "53fdde898feed8b027d94baa9cfe8229867f330a1d9c49dc7d84465ee7f229f7"
}

variable "image_datastore" {
  description = "Proxmox datastore to download the cloud image into (must accept 'iso' content)"
  type        = string
  default     = "local"
}

variable "disk_datastore" {
  description = "Proxmox datastore for the template VM's disks"
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}
