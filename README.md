# k3s in Proxmox

Provision a disposable k3s cluster on Proxmox VE with persistent SeaweedFS
storage. Built on the `bpg/proxmox` provider. See [requirements.md](requirements.md)
for full documentation and [security.md](security.md) for security measures.

## Getting started

### 1. Prerequisites

- Proxmox VE 8.x with API + SSH access
- Terraform >= 1.4
- Ansible on your workstation
- An SSH key pair (`~/.ssh/id_ed25519`)

### 2. One-time Proxmox setup

Run the setup script as root on the PVE host. It creates a PVE API
user/token and a restricted SSH user (`tfprov`) for snippet uploads.
Template creation is **off by default** — the `vm_template` Terraform
module handles that. See [security.md](security.md) for details.

```bash
cd terraform/scripts

# Default: PVE user/token + SSH service user only (template via Terraform)
./proxmox_setup.sh --host 192.168.1.2 --ssh-key ~/.ssh/id_ed25519

# Optional: also create the cloud-init template via the script
./proxmox_setup.sh --host 192.168.1.2 --ssh-key ~/.ssh/id_ed25519 --create-template
```

Save the token secret from the output. The script prints a
`terraform.tfvars` block — copy it to `terraform/terraform.tfvars`.

The script does **not** modify SSH settings on your PVE host. It only
creates a new user. Your root SSH access is left untouched.

### 3. Provision the cluster

```bash
cd ..  # back to terraform/
cp terraform.tfvars.example terraform.tfvars  # edit with your values
terraform init
terraform apply
```

Terraform creates the template (optional) and clones it into
control-plane, worker, and storage VMs. It also generates
`ansible/inventory.ini`.

### 4. Configure with Ansible

```bash
cd ../ansible
ansible-playbook -i inventory.ini site.yml
```

Ansible installs k3s, Cilium, Helm, Flux, and SeaweedFS.

## Structure

```
terraform/
  main.tf                 Module usage (edit this)
  versions.tf             Provider pinning
  providers.tf            Provider config
  variables.tf            Root variables
  terraform.tfvars.example
  .env_example
  scripts/
    proxmox_setup.sh       One-time PVE setup
  modules/
    vm_template/           Creates a cloud-init template
    k8s_cluster/           Clones template into VMs, generates ansible inventory
ansible/
  site.yml                 common -> k3s -> k3s_server -> k3s_agent -> storage
  README.md                Ansible documentation
  group_vars/
    all.yml                Ansible config (cilium, helm, flux URLs)
    control_plane.yml      Extra packages for control plane
    k3s_cluster.yml        kernel-modules-extra for k3s nodes
    storage.yml            SeaweedFS config (create from example)
  roles/
    common/                Package update, SSH hardening, sudo
    k3s/                   Swap, kernel modules, sysctl for k8s
    k3s_server/            k3s server, Cilium, Helm, Flux
    k3s_agent/             k3s agent join
    storage/               Data disk, firewall, Docker, SeaweedFS
```

## Roles

| Role | Target | Purpose |
| --- | --- | --- |
| `common` | all nodes | Package update, SSH hardening, sudo, reboot |
| `k3s` | k3s nodes | Swap off, kernel modules, sysctl |
| `k3s_server` | control plane | k3s server, Cilium, Helm, Flux |
| `k3s_agent` | workers | k3s agent join |
| `storage` | storage nodes | Data disk, firewall, Docker, SeaweedFS |

## Terraform and Ansible separation

Terraform generates `ansible/inventory.ini` with infrastructure facts
(IPs, users, SSH key path, control plane IP, cluster CIDRs). All ansible
configuration (cilium versions, install URLs, reboot policy) lives in
committed `ansible/group_vars/all.yml`. Ansible can run standalone with
a manual inventory.

## Workflow

- **Swap clusters**: `terraform destroy` -> edit `main.tf` -> `terraform apply` -> `ansible-playbook site.yml`
- **Storage survives destroy**: storage VMs have `prevent_destroy = true`. To destroy the cluster but keep storage, remove the storage resource from state first: `terraform state rm module.k3s_cluster.proxmox_virtual_environment_vm.storage["storage1"]`, then `terraform destroy`.
- **Full decommission**: remove storage from state as above, then `terraform destroy`

## Security

See [security.md](security.md) for full documentation including:
- Proxmox host SSH setup and lockout protection
- PVE API permissions
- VM SSH hardening and sudo configuration
- Storage node firewall
- Production recommendations
