# vm_template module

Creates a Rocky Linux 10 cloud-init template on Proxmox VE. The template
has qemu-guest-agent pre-installed via a vendor cloud-init snippet so
cloned VMs boot with the agent running.

## Three ways to get a template

1. **This module (default)**: downloads a Rocky 10 cloud image and
   creates a template VM with a vendor cloud-init snippet that installs
   qemu-guest-agent.
2. **This module (existing image)**: set `image_url = null` and provide
   `image_file_id` to use an image already on the Proxmox node.
3. **`proxmox_setup.sh --create-template`**: creates the template via
   shell commands on the PVE host. Use this if you prefer not to manage
   the template in Terraform state.

In all cases, pass the template's VM ID to the `k3s_cluster` module's
`template_vm_id` variable. The cluster module clones whatever template
is at that ID.

## Usage

```hcl
module "vm_template" {
  source = "./modules/vm_template"

  proxmox_node    = "server01"
  template_vm_id  = 9001
  vm_user         = "mora"
  ssh_public_keys = [trimspace(file(pathexpand("~/.ssh/id_ed25519.pub")))]
}
```

## Using an existing image

Set `image_url = null` and provide `image_file_id` to use an image
already on the Proxmox node instead of downloading one.

## Using an existing template

Skip this module entirely and pass the existing template's VM ID directly
to the `k3s_cluster` module's `template_vm_id` variable.

## VM configuration

All VMs use OVMF (UEFI), q35 machine type, and CPU type `max`.

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | --- |
| `proxmox_node` | Proxmox node name. | `string` | n/a | yes |
| `template_vm_id` | VM ID for the template. | `number` | n/a | yes |
| `vm_user` | Cloud-init username. | `string` | n/a | yes |
| `template_name` | Template VM name. | `string` | `rocky10-cloudinit` | no |
| `datastore_id` | Boot disk datastore. | `string` | `local-lvm` | no |
| `image_url` | Cloud image URL to download. | `string` | Rocky 10 URL | no |
| `image_file_id` | Existing image file ID. | `string` | `null` | no |
| `cores` | CPU cores. | `number` | `2` | no |
| `memory` | Memory in MB. | `number` | `2048` | no |
| `disk_size_gb` | Boot disk size in GB. | `number` | `20` | no |
| `ssh_public_keys` | SSH keys to inject. | `list(string)` | `[]` | no |
| `tags` | Proxmox tags. | `list(string)` | `["template","rocky10"]` | no |
| `network_bridge` | Network bridge. | `string` | `vmbr0` | no |

## Outputs

| Name | Description |
| --- | --- |
| `template_vm_id` | VM ID of the template. |
| `template_vm_name` | Name of the template. |
