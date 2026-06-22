# k8s_cluster module

Clones a cloud-init template into k3s cluster VMs and optional storage
VMs on Proxmox VE. Built for the `bpg/proxmox` provider.

## Usage

See `terraform/main.tf` for the intended usage. The module accepts
`template_vm_id` (a number) and clones whatever template is at that ID.

## Roles

| Role | Ansible group | In k3s | Extra disk | Purpose |
| --- | --- | --- | --- | --- |
| `control-plane` | `control_plane` | yes | no | k3s server, at least one |
| `worker` | `worker` | yes | no | k3s agent |
| `storage` | `storage` | no | scsi1 | SeaweedFS for PVCs |

## Lifecycle

CPU and memory changes are applied in-place with an automatic reboot
(`reboot_after_update = true`). Disk size changes grow the disk live via
`hotplug`. None of these recreate the VM.

## Ansible integration

When `ansible.enabled = true`, the module generates `inventory.ini` in
the configured ansible directory. The inventory contains infrastructure
facts only (IPs, users, SSH key path, control plane IP, cluster CIDRs).
All ansible configuration lives in committed `group_vars/` files.

## See also

- `requirements.md` for the full project documentation
- `terraform/scripts/proxmox_setup.sh` for one-time PVE setup
- `terraform/modules/vm_template/README.md` for template creation options

## Storage VMs and terraform destroy

Storage VMs have `prevent_destroy = true` in their lifecycle. A
`terraform destroy` will fail on storage resources with a clear error.
To destroy the cluster but keep storage:

```bash
terraform state rm module.k3s_cluster.proxmox_virtual_environment_vm.storage["storage1"]
terraform destroy
```

The storage VM stays running on Proxmox, outside Terraform's control.
To bring it back under Terraform management later:

```bash
terraform import module.k3s_cluster.proxmox_virtual_environment_vm.storage["storage1"] server01/301
```
