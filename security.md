# Security

This document covers the security measures applied by the project, the
permissions required for each component, and how to avoid lockout
scenarios.

## Proxmox host

### Getting started (one-time setup)

The `proxmox_setup.sh` script requires root SSH access to the PVE host
because it runs `pveum`, `qm`, and `pvesm` commands. After setup,
Terraform uses the API token for VM management and root SSH for snippet
uploads (the bpg provider writes to `/var/lib/vz/snippets/` which
requires root).

```bash
# Default: PVE user/token only (template via Terraform module)
cd terraform/scripts
./proxmox_setup.sh --host 192.168.1.2 --ssh-key ~/.ssh/id_ed25519

# Optional: also create the cloud-init template via the script
./proxmox_setup.sh --host 192.168.1.2 --ssh-key ~/.ssh/id_ed25519 --create-template
```

The script:
1. Creates a PVE role (`TerraformProv`) with minimum VM management privileges
2. Creates a PVE user (`terraform-prov@pve`) with that role
3. Generates an API token for the user
4. Optionally (with `--create-template`): downloads Rocky 10, creates the
   template VM, and creates the qemu-guest-agent snippet

**The script does NOT modify SSH settings on your PVE host.** Your root
SSH access, password authentication settings, and sshd_config are left
untouched.

### Why root SSH is required for Terraform

The bpg provider uses SSH to upload cloud-init snippets to the PVE host.
The snippets directory (`/var/lib/vz/snippets/`) is owned by root, and
the provider does not support sudo escalation for this operation. This
means `proxmox_ssh_user` must be `root` in your `terraform.tfvars`.

The API token (not SSH) is used for all other VM management operations
(create, clone, start, stop, configure). SSH is only used for snippet
uploads.

### PVE API permissions

The `TerraformProv` role has these privileges:

```
Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Datastore.Allocate
Pool.Allocate Pool.Audit
Sys.Audit Sys.Console Sys.Modify
VM.Allocate VM.Audit VM.Clone
VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk
VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options
VM.Migrate VM.PowerMgmt SDN.Use
VM.GuestAgent.Audit VM.GuestAgent.Unrestricted
```

These are the minimum required for the bpg provider to manage VMs. The
token has privilege separation disabled (`--privsep 0`) so it inherits
all user permissions.

## VMs (k3s nodes and storage)

### SSH hardening

Applied by the `common` ansible role on all VMs (not the PVE host).
Controlled by `ssh_hardening_enabled: true` (default). Set to `false` in
`group_vars/all.yml` to disable.

| Setting | Default | Why |
| --- | --- | --- |
| PermitRootLogin | `no` | No direct root SSH to VMs |
| PasswordAuthentication | `no` | Key-based auth only on VMs |
| MaxAuthTries | `3` | Brute-force limit |
| LoginGraceTime | `30` | Drop slow connections |

### Lockout protection on VMs

SSH hardening only runs after the `common` role has established a
working SSH connection (ansible connects via the cloud-init user's SSH
key). The `sshd -t` validation in the task prevents malformed config
from being written. The `restart sshd` handler runs at the end of the
play, not immediately, so all other tasks complete first.

If SSH hardening locks you out of a VM:
- Use the Proxmox web console to access the VM
- Log in with the cloud-init password (still works on the console)
- Fix `/etc/ssh/sshd_config` and run `systemctl restart sshd`

To disable SSH hardening entirely:
```yaml
# ansible/group_vars/all.yml
ssh_hardening_enabled: false
```

### Sudo

The cloud-init user has `NOPASSWD: ALL` sudo via a dedicated file in
`/etc/sudoers.d/<user>`. This is required for Ansible to run privileged
tasks without interactive password prompts. The file is validated with
`visudo -cf` before being written. Cloud-init's default wildcard
sudoers file (`90-cloud-init-users`) is removed to prevent duplicates.

### Storage node firewall

Optional, disabled by default. To enable:

```yaml
# ansible/group_vars/storage.yml
seaweedfs_firewall_enabled: true
seaweedfs_allowed_cidr: "10.0.0.0/24"  # your cluster subnet
```

When enabled, uses `firewalld` (Rocky 10 native) to restrict SeaweedFS
ports to the specified CIDR:

| Port | Service | Access |
| --- | --- | --- |
| 22 | SSH | Any (key-based only) |
| 8333 | SeaweedFS S3 | `seaweedfs_allowed_cidr` only |
| 9333 | SeaweedFS Master | `seaweedfs_allowed_cidr` only |
| 8888 | SeaweedFS Filer | `seaweedfs_allowed_cidr` only |

**Set `seaweedfs_allowed_cidr` to your actual cluster subnet.** The
default empty value means the firewall task won't run (it's guarded by
`seaweedfs_firewall_enabled`). If you enable the firewall but forget
the CIDR, the task will fail with a clear error.

## Recommendations for production

- Rotate the PVE API token periodically
- Use a VPN or jump host instead of exposing the PVE API to the internet
- Pin the SeaweedFS image to a specific version instead of `latest`
- Set `seaweedfs_allowed_cidr` to the exact cluster CIDR
- Consider adding `fail2ban` on the PVE host for SSH brute-force protection
- Consider using Proxmox API token privilege separation for finer control
- Review the sudoers file periodically: `visudo -c`
