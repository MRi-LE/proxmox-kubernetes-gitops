# terraform/modules/proxmox-template/main.tf
#
# Downloads an Ubuntu cloud image into Proxmox storage and converts it into
# a cloud-init VM template. The proxmox-vm module clones from this template.
#
# Resources:
#   proxmox_virtual_environment_download_file  — fetches the .img into Proxmox
#   proxmox_virtual_environment_vm             — creates + converts to template
#
# Apply order: this module must be applied before the proxmox-vm modules.
# Terraform handles this automatically via the `depends_on` in main.tf.

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.109.0"
    }
  }
}

# ── Download cloud image into Proxmox ISO/snippet storage ─────────────────────
# The provider downloads directly on the Proxmox host — no local bandwidth used.
resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  node_name    = var.node_name
  content_type = "iso"             # Proxmox stores raw images under "iso"
  datastore_id = var.image_datastore

  file_name = "${var.template_name}.img"
  url       = var.ubuntu_image_url

  # Skip re-download if the file already exists with the same checksum
  overwrite         = false
  checksum          = var.ubuntu_image_checksum
  checksum_algorithm = "sha256"
}

# ── Build the template VM ──────────────────────────────────────────────────────
resource "proxmox_virtual_environment_vm" "template" {
  name      = var.template_name
  vm_id     = var.template_vm_id
  node_name = var.node_name

  # Mark as template — Proxmox locks it; clones are the only allowed operation
  template  = true

  # ── CPU ─────────────────────────────────────────────────────────────────────
  cpu {
    cores = 2
    type  = "host"
  }

  # ── Memory ──────────────────────────────────────────────────────────────────
  memory {
    dedicated = 2048
  }

  # ── Root disk — imported from the downloaded cloud image ──────────────────
  disk {
    datastore_id = var.disk_datastore
    interface    = "scsi0"
    file_id      = proxmox_virtual_environment_download_file.ubuntu_cloud_image.id
    size         = 8    # base image size; clones resize to their own var.disk_size
    file_format  = "raw"
    discard      = "on"
  }

  # ── Network ─────────────────────────────────────────────────────────────────
  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  # ── Serial console (required for cloud images) ────────────────────────────
  serial_device {}

  # ── VGA via serial ────────────────────────────────────────────────────────
  vga {
    type = "serial0"
  }

  # ── QEMU guest agent ──────────────────────────────────────────────────────
  agent {
    enabled = true
  }

  # ── Boot order ────────────────────────────────────────────────────────────
  boot_order    = ["scsi0"]
  scsi_hardware = "virtio-scsi-single"

  # Template VMs are never started
  started = false

  # Once created as a template, Proxmox prevents most changes.
  # Ignore drift on fields Proxmox rewrites internally.
  lifecycle {
    ignore_changes = [
      disk,
      network_device,
      started,
    ]
  }

  depends_on = [
    proxmox_virtual_environment_download_file.ubuntu_cloud_image,
  ]
}
