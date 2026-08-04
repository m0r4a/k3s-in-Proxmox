# k3s_cluster module

Clones a cloud-init template into the (disposable) k3s cluster VMs on
Proxmox VE. Built for the `bpg/proxmox` provider. Storage VMs live in the
separate `storage_node` module / `terraform/storage` root.

## Usage

See `terraform/cluster/main.tf` for the intended usage. The module accepts
`template_vm_id` (a number) and clones whatever template is at that ID.

## Roles

| Role | Ansible group | In k3s | Purpose |
| --- | --- | --- | --- |
| `control-plane` | `control_plane` | yes | k3s server, at least one |
| `worker` | `worker` | yes | k3s agent |

## Lifecycle

CPU and memory changes are applied in-place with an automatic reboot
(`reboot_after_update = true`). Disk size changes grow the disk live via
`hotplug`. None of these recreate the VM.

## Ansible integration

When `ansible.enabled = true`, the module writes
`inventory.d/10-cluster.ini` in the configured ansible directory. The
fragment contains infrastructure facts only (IPs, users, SSH key path,
control plane IP, cluster CIDRs) for the `control_plane` and `worker`
groups. Ansible reads the whole `inventory.d/` directory, merging this
fragment with the `20-storage.ini` fragment written by the `storage_node`
module. All ansible configuration lives in committed `group_vars/` files.

## See also

- `requirements.md` for the full project documentation
- `terraform/modules/storage_node/README.md` for the long-lived storage half
- `terraform/scripts/proxmox_setup.sh` for one-time PVE setup
- `terraform/modules/vm_template/README.md` for template creation options
