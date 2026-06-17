# terraform/envs/homelab/main.tf

terraform {
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.109.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_tls_insecure
  ssh {
    username    = "root"
    agent       = false
    private_key = var.proxmox_ssh_private_key
  }
}

# ── Ubuntu 24.04 cloud-init template ──────────────────────────────────────────
# Downloads the cloud image and creates the template VM in Proxmox.
# All proxmox-vm modules depend on this implicitly via template_name output.
module "ubuntu_template" {
  source = "../../modules/proxmox-template"

  node_name       = var.proxmox_node
  template_name   = var.template_name
  template_vm_id  = var.template_vm_id
  bridge          = var.network_bridge
  disk_datastore  = var.disk_datastore
  image_datastore = var.image_datastore

  # Image URL + checksum are pinned in the module variables.tf.
  # Override here only if you need a different Ubuntu release.
  # ubuntu_image_url      = "https://..."
  # ubuntu_image_checksum = "sha256:..."
}

# ── Control Plane ──────────────────────────────────────────────────────────────
module "k8s_cp_01" {
  source = "../../modules/proxmox-vm"

  vm_name        = "k8s-cp-01"
  vm_id          = 201
  node_name      = var.proxmox_node
  template       = module.ubuntu_template.template_name
  cpu            = 2
  memory_mb      = 4096
  disk_size      = 30
  ip_address     = var.cp01_ip
  gateway        = var.network_gateway
  bridge         = var.network_bridge
  ssh_public_key = var.ansible_ssh_public_key
  disk_datastore = var.disk_datastore

  depends_on = [module.ubuntu_template]
}

# ── Workers ───────────────────────────────────────────────────────────────────
module "k8s_worker_01" {
  source = "../../modules/proxmox-vm"

  vm_name        = "k8s-worker-01"
  vm_id          = 202
  node_name      = var.proxmox_node
  template       = module.ubuntu_template.template_name
  cpu            = 2
  memory_mb      = 6144
  disk_size      = 40
  ip_address     = var.worker01_ip
  gateway        = var.network_gateway
  bridge         = var.network_bridge
  ssh_public_key = var.ansible_ssh_public_key
  disk_datastore = var.disk_datastore

  depends_on = [module.ubuntu_template]
}

module "k8s_worker_02" {
  source = "../../modules/proxmox-vm"

  vm_name        = "k8s-worker-02"
  vm_id          = 203
  node_name      = var.proxmox_node
  template       = module.ubuntu_template.template_name
  cpu            = 2
  memory_mb      = 6144
  disk_size      = 40
  ip_address     = var.worker02_ip
  gateway        = var.network_gateway
  bridge         = var.network_bridge
  ssh_public_key = var.ansible_ssh_public_key
  disk_datastore = var.disk_datastore

  depends_on = [module.ubuntu_template]
}
