# Requirements

Provision a disposable k3s cluster on Proxmox VE with persistent SeaweedFS
storage for PVCs. The cluster is rebuilt with a single `terraform destroy`
+ `terraform apply` + a FluxCD target change.

## Goals

1. Migrate from telmate/proxmox to bpg/proxmox provider.
2. Terraform modules: `vm_template` (creates a cloud-init template),
   `k3s_cluster` (clones that template into the k3s VMs), and
   `storage_node` (clones it into the long-lived storage VMs). The cluster
   and storage modules accept a `template_vm_id` so they work with either
   the template module or a pre-existing template (e.g. one created by
   `proxmox_setup.sh`). The cluster and storage modules run from separate
   Terraform roots with separate state (`terraform/cluster`,
   `terraform/storage`) so a cluster destroy cannot touch storage.
3. Fix lifecycle management: changing CPU or RAM on a VM must not
   recreate it. The bpg provider updates `cpu.cores` and `memory.dedicated`
   in-place and reboots via `reboot_after_update = true`.
4. Add a `storage` role for a VM that runs SeaweedFS in Docker to manage
   PVCs. This VM is outside the k3s cluster.
5. The end goal: the k3s cluster is one `terraform destroy` away, and a
   new cluster can be spun up by changing where FluxCD points and running
   `terraform apply`.

## Architecture

```
.
├── terraform/
│   ├── cluster/                # ROOT #1: disposable k3s cluster (own state)
│   │   ├── main.tf             #   How you use the modules (edit this)
│   │   ├── versions.tf / providers.tf / variables.tf / terraform.tfvars.example
│   ├── storage/                # ROOT #2: long-lived storage (own state)
│   │   ├── main.tf             #   How you use the storage module (edit this)
│   │   ├── versions.tf / providers.tf / variables.tf / terraform.tfvars.example
│   ├── scripts/
│   │   └── proxmox_setup.sh    # One-time PVE setup (role, user, token, template)
│   └── modules/
│       ├── vm_template/        # Creates a cloud-init template
│       ├── k3s_cluster/        # Clones template into k3s VMs, writes 10-cluster.ini
│       └── storage_node/       # Clones template into storage VMs, writes 20-storage.ini
└── ansible/
    ├── site.yml                # Orchestrates all roles
    ├── README.md               # Ansible documentation
    ├── inventory.d/            # Generated inventory fragments, read as a directory
    │   ├── 10-cluster.ini      #   From the cluster root (gitignored)
    │   ├── 20-storage.ini      #   From the storage root (gitignored)
    │   └── *.ini.example       #   Standalone example fragments (committed)
    ├── group_vars/
    │   ├── all.yml             # Ansible config (cilium, helm, flux URLs)
    │   ├── all-example.yml     # Example mirror of all.yml
    │   ├── control_plane.yml   # Extra packages for control plane
    │   ├── k3s_cluster.yml     # kernel-modules-extra for k3s nodes
    │   └── storage.yml         # SeaweedFS config (create from example)
    └── roles/
        ├── common/             # Package update, base packages, reboot
        ├── k3s/                # Swap, kernel modules, sysctl for k3s
        ├── k3s_server/         # k3s server, Cilium, Helm, Flux, Hubble
        ├── k3s_agent/          # k3s agent join
        └── storage/            # Data disk, Docker, SeaweedFS
```

## Terraform and Ansible separation

Terraform owns infrastructure (VMs, IPs, networks). Ansible owns
configuration (packages, k3s, cilium, seaweedfs).

The connection point is the `inventory.d/` directory. Each Terraform root
writes one fragment (`10-cluster.ini`, `20-storage.ini`) with
infrastructure facts only: IPs, users, SSH key path, control plane IP,
cluster CIDRs. Ansible reads the directory and merges the fragments. All
ansible configuration (cilium versions, install URLs, reboot policy) lives
in committed `ansible/group_vars/all.yml`.

Ansible can run standalone with manual fragments — it does not depend on
terraform at runtime, only on the inventory fragment format.

## Roles

| Role            | Ansible group   | In k3s | Extra disk | Purpose                            |
| --------------- | --------------- | ------ | ---------- | ---------------------------------- |
| `control-plane` | `control_plane` | yes    | no         | Runs the k3s server. At least one. |
| `worker`        | `worker`        | yes    | no         | Schedules workloads.               |
| `storage`       | `storage`       | no     | scsi1      | Hosts SeaweedFS for PVCs.          |

## Lifecycle (no recreation on CPU/RAM change)

The bpg provider's `proxmox_virtual_environment_vm` updates `cpu.cores`
and `memory.dedicated` in-place. With `reboot_after_update = true` it
reboots the VM automatically. Disk size changes grow the disk live via
`hotplug = "network,disk,usb"`. None of these recreate the VM.

## Template design

The template is a Rocky Linux 10 cloud-init image converted to a Proxmox
template with qemu-guest-agent pre-installed.

Three ways to create the template:

1. **`vm_template` module (default)**: downloads a cloud image and
   creates a template VM with a vendor cloud-init snippet that installs
   qemu-guest-agent. This is the recommended path — the template is
   managed in Terraform state.
2. **`vm_template` module (existing image)**: set `image_url = null` and
   provide `image_file_id` to use an image already on the Proxmox node.
3. **`proxmox_setup.sh --create-template`**: creates the template via
   shell commands on the Proxmox node. Off by default; the script only
   creates the PVE user/token and SSH service user unless you pass
   `--create-template`.

The `k3s_cluster` module accepts `template_vm_id` and clones whatever
template is at that ID. It does not care how the template was created.

### vm_template: download vs existing image

- `image_url` (default): downloads a cloud image from a URL.
- `image_file_id`: uses an existing image on Proxmox. Set `image_url = null`.

## VM configuration

- BIOS: OVMF (UEFI)
- Machine: q35
- CPU type: max
- EFI disk: 4m, raw format
- SCSI hardware: virtio-scsi-single
- Boot order: scsi0
- Agent: enabled on clones (template has qemu-guest-agent pre-installed)
- Hotplug: network, disk, usb (live disk/NIC changes)

## bpg provider mapping (telmate -> bpg)

| telmate | bpg | Notes |
| --- | --- | --- |
| `proxmox_vm_qemu` | `proxmox_virtual_environment_vm` | |
| `clone = "name"` | `clone { vm_id = 9000 }` | bpg clones by VM ID |
| `scsihw = "virtio-scsi-single"` | `scsi_hardware = "virtio-scsi-single"` | |
| `boot = "order=scsi0"` | `boot_order = ["scsi0"]` | |
| `agent = 1` | `agent { enabled = true }` | |
| `cicustom = "vendor=..."` | `initialization { vendor_data_file_id = ... }` | |
| `ipconfig0 = "ip=..."` | `initialization { ip_config { ipv4 { address = ... } } }` | |
| `ciuser`, `cipassword`, `sshkeys` | `initialization { user_account { ... } }` | |
| `disks { scsi { scsi0 { ... } } }` | `disk { datastore_id, interface, size }` | |
| `network { bridge, model }` | `network_device { bridge, model }` | |
| `serial { id = 0 }` | `serial_device { device = "socket" }` | |
| `vm_state = "running"` | `started = true` | |
| `automatic_reboot = true` | `reboot_after_update = true` | |

## Cluster swap workflow

1. `cd terraform/cluster && terraform destroy` — cluster gone; storage
   (separate root/state) is untouched.
2. Change FluxCD target / node IPs / node counts in `cluster/main.tf`.
3. `cd terraform/cluster && terraform apply` — new cluster up.
4. `cd ../../ansible && ansible-playbook -i inventory.d/ site.yml`

## Prerequisites

- Proxmox VE 8.x with API + SSH access.
- Terraform >= 1.4.
- Ansible on your workstation.
- SSH key pair for the Proxmox node and the VMs.
- A PVE API user + token (created by `proxmox_setup.sh` or manually).
- The `snippets` content type enabled on the `local` storage.
