output "vm_ids" {
  description = "Map of node key -> provisioned VM ID."
  value       = { for key, node in proxmox_virtual_environment_vm.node : key => node.vm_id }
}

output "control_plane_ip" {
  description = "IP of the first control-plane node."
  value       = local.control_plane_ip
}

output "k3s_node_ips" {
  description = "IPs of the k3s cluster members."
  value = [
    for _, node in local.nodes_normalized : node.ip
  ]
}
