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

### 3. Provision the infrastructure (two roots)

The cluster and the storage node live in **separate Terraform roots with
separate state**, so a cluster `terraform destroy` never touches storage.

Storage is long-lived — apply it once. It clones an existing template, so
create the template first (via the cluster root's `vm_template` module, or
`proxmox_setup.sh --create-template`), then:

```bash
cd terraform/storage
cp main.tf.example main.tf                     # edit storage node definitions
cp terraform.tfvars.example terraform.tfvars   # edit with your values
terraform init
terraform apply                                # writes ansible/inventory.d/20-storage.ini
```

The cluster is disposable — apply/destroy at will:

```bash
cd ../cluster
cp main.tf.example main.tf                      # edit control-plane/worker nodes
cp terraform.tfvars.example terraform.tfvars    # edit with your values
terraform init
terraform apply                                 # writes ansible/inventory.d/10-cluster.ini
```

The shared Proxmox connection values can live in one file passed to both
roots with `terraform apply -var-file=../common.tfvars`.

### 4. Configure with Ansible

Point Ansible at the `inventory.d/` directory — it merges both fragments:

```bash
cd ../../ansible
ansible-playbook -i inventory.d/ site.yml
```

Ansible installs k3s, Cilium, Helm, Flux, and SeaweedFS.

## Structure

```
terraform/
  cluster/                 ROOT #1 - disposable k3s cluster (own state)
    main.tf.example          Module usage (copy to main.tf, edit nodes)
    versions.tf / providers.tf / variables.tf / terraform.tfvars.example
  storage/                 ROOT #2 - long-lived storage (own state)
    main.tf.example          Module usage (copy to main.tf, edit nodes)
    versions.tf / providers.tf / variables.tf / terraform.tfvars.example
  scripts/
    proxmox_setup.sh       One-time PVE setup
  modules/
    vm_template/           Creates a cloud-init template
    k3s_cluster/           Clones template into k3s VMs, writes 10-cluster.ini
    storage_node/          Clones template into storage VMs, writes 20-storage.ini
ansible/
  site.yml                 common -> k3s -> k3s_server -> k3s_agent -> storage
  README.md                Ansible documentation
  inventory.d/             Generated inventory fragments (read as a directory)
    10-cluster.ini           From the cluster root (gitignored)
    20-storage.ini           From the storage root (gitignored)
  group_vars/
    all.yml                Ansible config (cilium, helm, flux URLs)
    control_plane.yml      Extra packages for control plane
    k3s_cluster.yml        kernel-modules-extra for k3s nodes
    storage.yml            SeaweedFS config (create from example)
  roles/
    common/                Package update, SSH hardening, sudo
    k3s/                   Swap, kernel modules, sysctl for k3s
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

Each Terraform root writes its own fragment into `ansible/inventory.d/`
with infrastructure facts (IPs, users, SSH key path, control plane IP,
cluster CIDRs): the cluster root writes `10-cluster.ini`, the storage root
writes `20-storage.ini`. Ansible reads the whole directory and merges them.
All ansible configuration (cilium versions, install URLs, reboot policy)
lives in committed `ansible/group_vars/all.yml`. Ansible can run standalone
with manual fragments (copy the `*.ini.example` files).

## Workflow

- **Swap clusters** (storage untouched): `cd terraform/cluster && terraform destroy` -> edit `main.tf` -> `terraform apply` -> `cd ../../ansible && ansible-playbook -i inventory.d/ site.yml`
- **Storage survives destroy**: storage is a separate root/state, so a cluster `terraform destroy` cannot reach it. The storage VM also sets `prevent_destroy = true` as a guard against destroying the storage root by accident.
- **Reconfigure only storage**: `ansible-playbook -i inventory.d/ site.yml --limit storage`
- **Intentional storage teardown**: comment out `prevent_destroy` in `modules/storage_node/main.tf`, then `cd terraform/storage && terraform destroy`.

## Security

See [security.md](security.md) for full documentation including:
- Proxmox host SSH setup and lockout protection
- PVE API permissions
- VM SSH hardening and sudo configuration
- Storage node firewall
- Production recommendations
