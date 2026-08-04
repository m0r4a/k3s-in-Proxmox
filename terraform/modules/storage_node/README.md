# storage_node module

Clones a cloud-init template into one or more long-lived **storage VMs** on
Proxmox VE and writes the Ansible inventory fragment for them. Built for the
`bpg/proxmox` provider.

Each storage VM gets a second SCSI disk (`scsi1`, sized by `storage_disk_gb`)
that the Ansible `storage` role formats, mounts at `/mnt/data`, and hands to
SeaweedFS. Storage nodes are **not** k3s members.

## Why a separate module / root

Storage holds SeaweedFS PVC data and must outlive the disposable k3s cluster.
Running this module from its **own Terraform root/state** (`terraform/storage/`)
means a `terraform destroy` of the cluster root can never touch it. The VM also
sets `prevent_destroy = true` as a guard against an accidental destroy of the
storage root itself — comment it out in `main.tf` for an intentional teardown.

## Template

This module does not create the cloud-init template. Pass `template_vm_id` of an
existing template — one made by the cluster root's `vm_template` module or by
`proxmox_setup.sh --create-template`. Create the template before applying this
root.

## Ansible integration

When `ansible.enabled = true`, the module writes
`<ansible.path>/inventory.d/20-storage.ini` containing the `[storage]` group and
a self-contained `[storage:vars]` block (SSH key path, admin user). Ansible reads
the whole `inventory.d/` directory, merging this fragment with the cluster
fragment written by the `k3s_cluster` module.

## See also

- `../k3s_cluster/README.md` — the disposable cluster half.
- `requirements.md` for the full project documentation.
