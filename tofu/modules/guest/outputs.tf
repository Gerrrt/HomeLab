output "vm_id" {
  value = proxmox_virtual_environment_vm.this.vm_id
}

output "ipv4_addresses" {
  description = "As the guest agent reports them."
  value       = proxmox_virtual_environment_vm.this.ipv4_addresses
}

output "mac_address" {
  value = proxmox_virtual_environment_vm.this.network_device[0].mac_address
}
