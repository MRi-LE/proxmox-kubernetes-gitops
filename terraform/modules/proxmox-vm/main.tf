# terraform/modules/proxmox-vm/main.tf
# Creates a single VM on Proxmox by cloning a cloud-init template.
# Uses the bpg/proxmox provider (~> 0.109.0).

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.109.0"
    }
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  name      = var.vm_name
  vm_id     = var.vm_id
  node_name = var.node_name

  # ── Clone from template ──────────────────────────────────────────────────────
  clone {
    vm_id = data.proxmox_virtual_environment_vms.template.vms[0].vm_id
    full  = true
  }

  # ── CPU ─────────────────────────────────────────────────────────────────────
  cpu {
    cores = var.cpu
    type  = "host"
  }

  # ── Memory ──────────────────────────────────────────────────────────────────
  memory {
    dedicated = var.memory_mb
  }

  # ── Disk ────────────────────────────────────────────────────────────────────
  disk {
    datastore_id = var.disk_datastore
    interface    = "scsi0"
    size         = var.disk_size
    file_format  = "raw"
  }

  # ── Network ─────────────────────────────────────────────────────────────────
  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  # ── Cloud-init ──────────────────────────────────────────────────────────────
  initialization {
    ip_config {
      ipv4 {
        address = "${var.ip_address}/${var.cidr_prefix}"
        gateway = var.gateway
      }
    }

    user_account {
      username = var.ssh_user
      keys     = [var.ssh_public_key]
    }

    dns {
      servers = var.dns_servers
    }
  }

  # ── Serial console (required for cloud images) ────────────────────────────
  serial_device {}
  vga {
    type = "serial0"
  }

  # ── Agent ────────────────────────────────────────────────────────────────────
  agent {
    enabled = true
  }

  # ── Boot ────────────────────────────────────────────────────────────────────
  boot_order    = ["scsi0"]
  scsi_hardware = "virtio-scsi-single"

  on_boot   = true
  started   = true
  lifecycle {
    ignore_changes = [
      # cloud-init drive is ephemeral; ignore after first boot
      initialization,
    ]
  }
}

# Look up the template VM ID by name
data "proxmox_virtual_environment_vms" "template" {
  node_name = var.node_name
  filter {
    name   = "name"
    values = [var.template]
  }
}
