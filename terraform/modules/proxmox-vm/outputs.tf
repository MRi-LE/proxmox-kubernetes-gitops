# terraform/modules/proxmox-vm/outputs.tf

output "vm_id" {
  description = "Proxmox VM ID — useful for direct Proxmox API or CLI operations (e.g. qm start 201)"
  value       = proxmox_virtual_environment_vm.vm.vm_id
}

output "vm_name" {
  description = "VM display name in Proxmox — matches the hostname set via cloud-init"
  value       = proxmox_virtual_environment_vm.vm.name
}

output "ip_address" {
  description = "Static IP address assigned to this VM"
  value       = var.ip_address
}

output "ssh_user" {
  description = "Username created by cloud-init — consumed by generate_inventory.py as ansible_user"
  value       = var.ssh_user
}
