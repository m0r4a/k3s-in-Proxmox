locals {
  nodes_normalized = {
    for key, value in var.nodes : key => {
      vmid         = value.vmid
      role         = value.role
      hostname     = var.cluster_name != "" ? "${var.cluster_name}-${key}" : key
      user         = coalesce(value.user, var.vm_user)
      password     = coalesce(value.password, var.vm_password)
      cores        = coalesce(value.cores, var.cores)
      memory       = coalesce(value.memory, var.memory)
      disk_size_gb = coalesce(value.disk_size_gb, var.disk_size_gb)
      ip           = value.ip
      tags         = distinct(concat(var.tags, ["k3s", value.role], var.cluster_name != "" ? [var.cluster_name] : []))
      on_boot      = false
    }
  }

  control_plane_ip = one([
    for _, node in local.nodes_normalized : node.ip
    if node.role == "control-plane"
  ])

  is_public_ssh_key_path = can(regex("^[~./]", var.ssh_public_key))
  ssh_public_key_content = local.is_public_ssh_key_path ? trimspace(file(pathexpand(var.ssh_public_key))) : trimspace(var.ssh_public_key)
  ssh_private_key_path   = replace(var.ssh_private_key_path, ".pub", "")
}
