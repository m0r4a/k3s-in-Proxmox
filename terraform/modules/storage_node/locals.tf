locals {
  nodes_normalized = {
    for key, value in var.nodes : key => {
      vmid            = value.vmid
      hostname        = var.cluster_name != "" ? "${var.cluster_name}-${key}" : key
      user            = coalesce(value.user, var.vm_user)
      password        = coalesce(value.password, var.vm_password)
      cores           = coalesce(value.cores, var.cores)
      memory          = coalesce(value.memory, var.memory)
      disk_size_gb    = coalesce(value.disk_size_gb, var.disk_size_gb)
      storage_disk_gb = coalesce(value.storage_disk_gb, var.storage_disk_gb)
      ip              = value.ip
      tags            = distinct(concat(var.tags, ["storage"], var.cluster_name != "" ? [var.cluster_name] : []))
      on_boot         = true
    }
  }

  is_public_ssh_key_path = can(regex("^[~./]", var.ssh_public_key))
  ssh_public_key_content = local.is_public_ssh_key_path ? trimspace(file(pathexpand(var.ssh_public_key))) : trimspace(var.ssh_public_key)
  ssh_private_key_path   = replace(var.ssh_private_key_path, ".pub", "")
}
