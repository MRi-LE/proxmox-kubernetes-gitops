# terraform/modules/proxmox-template/outputs.tf

output "template_name" {
  description = "Template VM name — pass directly to proxmox-vm modules as `template`"
  value       = proxmox_virtual_environment_vm.template.name
}

output "template_vm_id" {
  description = "Proxmox VM ID of the template"
  value       = proxmox_virtual_environment_vm.template.vm_id
}
