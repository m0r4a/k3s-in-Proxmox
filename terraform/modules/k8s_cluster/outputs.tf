output "vm_ids" {
  description = "Map of node key -> provisioned VM ID."
  value = merge(
    { for key, node in proxmox_virtual_environment_vm.node : key => node.vm_id },
    { for key, node in proxmox_virtual_environment_vm.storage : key => node.vm_id },
  )
}

output "control_plane_ip" {
  description = "IP of the first control-plane node."
  value       = local.control_plane_ip
}

output "k3s_node_ips" {
  description = "IPs of the k3s cluster members (excludes storage)."
  value = [
    for _, node in local.k3s_nodes : node.ip
  ]
}

output "storage_node_ips" {
  description = "IPs of the storage-role nodes."
  value = [
    for _, node in local.storage_nodes : node.ip
  ]
}
