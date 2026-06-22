#!/usr/bin/env bash
# Configures a Proxmox node for Terraform provisioning with the bpg provider.
# Creates a PVE role/user/token and, optionally, a cloud-init template and a
# qemu-guest-agent snippet. The template can also be created by the
# vm_template Terraform module; pass --skip-template to keep using that path.

# Usage: ./proxmox-setup.sh --host <IP> [options]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die() {
	echo -e "${RED}[✗]${NC} $*" >&2
	exit 1
}
skip() { echo -e "${YELLOW}[~]${NC} $* — skipping"; }

PVE_HOST=""
SSH_USER="root"
SSH_KEY=""
SSH_PASS=""

ROLE_NAME="TerraformProv"
TF_USER="terraform-prov"
TF_REALM="pve"
TF_PASS=""
TOKEN_NAME="mytoken"

TEMPLATE_ID="9000"
TEMPLATE_NAME="rocky10-cloudinit"
STORAGE="local-lvm"
ROCKY_URL="https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
ROCKY_IMG="/root/rocky10-cloudinit.qcow2"
SNIPPET_PATH="/var/lib/vz/snippets/qemu-guest-agent.yml"

SKIP_TEMPLATE=true
SKIP_SNIPPET=true
UNINSTALL=false

ROLE_PRIVS="Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit \
Pool.Allocate Pool.Audit \
Sys.Audit Sys.Console Sys.Modify \
VM.Allocate VM.Audit VM.Clone \
VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk \
VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options \
VM.Migrate VM.PowerMgmt SDN.Use \
Datastore.Allocate \
VM.GuestAgent.Audit VM.GuestAgent.Unrestricted"

usage() {
	cat <<EOF
$(echo -e "${BOLD}proxmox_setup.sh${NC}") — Proxmox Terraform + cloud-init setup

$(echo -e "${BOLD}USAGE${NC}")
  $(basename "$0") --host <IP> [options]

$(echo -e "${BOLD}CONNECTION${NC}")
  --host <IP>            Proxmox node IP or hostname     (required)
  --ssh-user <user>      SSH login user                  (default: root)
  --ssh-key <path>       Path to private key             (recommended)
  --ssh-pass <pass>      SSH password (requires sshpass)

$(echo -e "${BOLD}TERRAFORM USER${NC}")
  --tf-user <name>       PVE username                    (default: terraform-prov)
  --tf-pass <pass>       PVE user password               (prompted if omitted)
  --token-name <name>    API token name                  (default: mytoken)

$(echo -e "${BOLD}TEMPLATE${NC}")
  --template-id <id>     VM ID for the template          (default: 9000)
  --template-name <name> VM name for the template        (default: rocky10-cloudinit)
  --storage <pool>       Proxmox storage pool            (default: local-lvm)
  --rocky-url <url>      Override Rocky Linux image URL

  --create-template      Create cloud-init template and snippet (skipped by
                         default; use the vm_template Terraform module instead)
  --skip-template        Skip template creation (default)
  --skip-snippet         Skip qemu-guest-agent snippet creation (default)

$(echo -e "${BOLD}TEARDOWN${NC}")
  --uninstall            Remove all resources created by this script

$(echo -e "${BOLD}EXAMPLES${NC}")
  # Setup PVE user/token + SSH service user (template via Terraform module):
  $(basename "$0") --host 192.168.1.10 --ssh-key ~/.ssh/id_ed25519

  # Full setup including template creation:
  $(basename "$0") --host 192.168.1.10 --ssh-key ~/.ssh/id_ed25519 --create-template

  # Tear everything down:
  $(basename "$0") --host 192.168.1.10 --ssh-key ~/.ssh/id_ed25519 --uninstall
EOF
	exit 0
}

# Args

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
	case "$1" in
	--host)
		PVE_HOST="$2"
		shift 2
		;;
	--ssh-user)
		SSH_USER="$2"
		shift 2
		;;
	--ssh-key)
		SSH_KEY="$2"
		shift 2
		;;
	--ssh-pass)
		SSH_PASS="$2"
		shift 2
		;;
	--tf-user)
		TF_USER="$2"
		shift 2
		;;
	--tf-pass)
		TF_PASS="$2"
		shift 2
		;;
	--token-name)
		TOKEN_NAME="$2"
		shift 2
		;;
	--template-id)
		TEMPLATE_ID="$2"
		shift 2
		;;
	--template-name)
		TEMPLATE_NAME="$2"
		shift 2
		;;
	--storage)
		STORAGE="$2"
		shift 2
		;;
	--rocky-url)
		ROCKY_URL="$2"
		shift 2
		;;
	--skip-template)
		SKIP_TEMPLATE=true
		shift
		;;
	--create-template)
		SKIP_TEMPLATE=false
		SKIP_SNIPPET=false
		shift
		;;
	--skip-snippet)
		SKIP_SNIPPET=true
		shift
		;;
	--uninstall)
		UNINSTALL=true
		shift
		;;
	--help | -h) usage ;;
	*) die "Unknown argument: $1" ;;
	esac
done

FULL_USER="${TF_USER}@${TF_REALM}"

[[ -z "$PVE_HOST" ]] && die "--host is required"
[[ -n "$SSH_KEY" && ! -f "$SSH_KEY" ]] && die "SSH key not found: $SSH_KEY"
[[ -z "$SSH_KEY" && -z "$SSH_PASS" ]] && die "Provide either --ssh-key or --ssh-pass"

if [[ -n "$SSH_PASS" ]] && ! command -v sshpass &>/dev/null; then
	die "'sshpass' is not installed. Use --ssh-key or install sshpass."
fi

# TF_PASS is only needed when creating the user, not for uninstall
if [[ "$UNINSTALL" == false && -z "$TF_PASS" ]]; then
	read -rsp "Password for ${FULL_USER} (terraform user in proxmox): " TF_PASS
	echo
	[[ -z "$TF_PASS" ]] && die "Password cannot be empty"
fi

# SSH
# ControlMaster opens one connection; every subsequent pve_exec reuses the socket.

SSH_SOCKET="/tmp/proxmox-setup-${$}"
SSH_OPTS=(
	-o StrictHostKeyChecking=no
	-o ConnectTimeout=10
	-o LogLevel=ERROR
	-o ControlMaster=auto
	-o ControlPath="${SSH_SOCKET}"
	-o ControlPersist=120
)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

ssh_close() {
	ssh -o ControlPath="${SSH_SOCKET}" -O exit "${SSH_USER}@${PVE_HOST}" 2>/dev/null || true
}
trap ssh_close EXIT

pve_exec() {
	if [[ -n "$SSH_PASS" ]]; then
		sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${PVE_HOST}" "$1"
	else
		ssh "${SSH_OPTS[@]}" "${SSH_USER}@${PVE_HOST}" "$1"
	fi
}

pve_check() {
	pve_exec "$1" &>/dev/null && return 0 || return 1
}

# Connectivity

info "Connecting to ${PVE_HOST}..."
pve_check "pvesh get /version" || die "Cannot reach Proxmox at ${PVE_HOST}. Check host and credentials."

PVE_VERSION=$(pve_exec "pvesh get /version --output-format json 2>/dev/null \
  | python3 -c \"import sys,json; print(json.load(sys.stdin)['version'])\"")
log "Proxmox VE ${PVE_VERSION}"

# Uninstall

if [[ "$UNINSTALL" == true ]]; then
	echo
	warn "This will destroy all resources created by this script."
	read -rp "  Continue? [y/N] " confirm
	[[ "${confirm,,}" != "y" ]] && die "Aborted"

	echo
	info "- API Token -"
	if pve_check "pveum user token list '${FULL_USER}' --output-format json | python3 -c \
    \"import sys,json; tokens=[t['tokenid'] for t in json.load(sys.stdin)]; exit(0 if '${TOKEN_NAME}' in tokens else 1)\""; then
		log "Removing token '${TOKEN_NAME}'..."
		pve_exec "pveum user token remove '${FULL_USER}' '${TOKEN_NAME}'"
		log "Token removed"
	else
		skip "Token '${TOKEN_NAME}' not found"
	fi

	echo
	info "- User -"
	if pve_check "pveum user list --output-format json | python3 -c \
    \"import sys,json; users=[u['userid'] for u in json.load(sys.stdin)]; exit(0 if '${FULL_USER}' in users else 1)\""; then
		log "Removing user '${FULL_USER}' (ACL removed automatically)..."
		pve_exec "pveum user delete '${FULL_USER}'"
		log "User removed"
	else
		skip "User '${FULL_USER}' not found"
	fi

	echo
	info "- Role -"
	if pve_check "pveum role list --output-format json | python3 -c \
    \"import sys,json; roles=[r['roleid'] for r in json.load(sys.stdin)]; exit(0 if '${ROLE_NAME}' in roles else 1)\""; then
		log "Removing role '${ROLE_NAME}'..."
		pve_exec "pveum role delete '${ROLE_NAME}'"
		log "Role removed"
	else
		skip "Role '${ROLE_NAME}' not found"
	fi

	echo
	info "- Snippet -"
	if pve_check "test -f '${SNIPPET_PATH}'"; then
		log "Removing snippet..."
		pve_exec "rm -f '${SNIPPET_PATH}'"
		log "Snippet removed"
	else
		skip "Snippet not found at ${SNIPPET_PATH}"
	fi

	echo
	info "- Cloud-init Template -"
	if pve_check "qm status ${TEMPLATE_ID}"; then
		log "Destroying template ${TEMPLATE_ID} (--purge removes disk)..."
		pve_exec "qm destroy ${TEMPLATE_ID} --purge"
		log "Template destroyed"
	else
		skip "VM ${TEMPLATE_ID} not found"
	fi

	echo
	echo -e "${GREEN}  Uninstall complete${NC}"
	echo
	exit 0
fi

echo
info "- Role -"

if pve_check "pveum role list --output-format json | python3 -c \
  \"import sys,json; roles=[r['roleid'] for r in json.load(sys.stdin)]; exit(0 if '${ROLE_NAME}' in roles else 1)\""; then
	skip "Role '${ROLE_NAME}' already exists"
else
	log "Creating role '${ROLE_NAME}'..."
	pve_exec "pveum role add '${ROLE_NAME}' -privs '${ROLE_PRIVS}'"
	log "Role created"
fi

echo
info "- User -"

if pve_check "pveum user list --output-format json | python3 -c \
  \"import sys,json; users=[u['userid'] for u in json.load(sys.stdin)]; exit(0 if '${FULL_USER}' in users else 1)\""; then
	skip "User '${FULL_USER}' already exists"
else
	log "Creating user '${FULL_USER}'..."
	pve_exec "pveum user add '${FULL_USER}' --password '${TF_PASS}'"
	log "User created"
fi

log "Assigning role '${ROLE_NAME}' to '${FULL_USER}' on /..."
pve_exec "pveum aclmod / -user '${FULL_USER}' -role '${ROLE_NAME}'"

echo
info "- API Token -"

TOKEN_OUTPUT=""

if pve_check "pveum user token list '${FULL_USER}' --output-format json | python3 -c \
  \"import sys,json; tokens=[t['tokenid'] for t in json.load(sys.stdin)]; exit(0 if '${TOKEN_NAME}' in tokens else 1)\""; then
	echo
	warn "Token '${TOKEN_NAME}' already exists — the secret is not recoverable."
	warn "To regenerate it, delete the token and re-run:"
	warn "  pveum user token remove '${FULL_USER}' '${TOKEN_NAME}'"
	echo
else
	log "Generating token '${TOKEN_NAME}' (privilege separation disabled)..."
	TOKEN_OUTPUT=$(pve_exec "pveum user token add '${FULL_USER}' '${TOKEN_NAME}' --privsep 0")
	log "Token generated"
fi

if [[ "$SKIP_SNIPPET" == false ]]; then
	echo
	info "- Snippet -"

	if pve_check "test -f '${SNIPPET_PATH}'"; then
		skip "Snippet already exists at ${SNIPPET_PATH}"
	else
		log "Creating snippets directory..."
		pve_exec "mkdir -p /var/lib/vz/snippets"

		log "Enabling snippets content type on 'local' storage..."
		pve_exec "pvesm set local --content vztmpl,iso,snippets,backup,images 2>/dev/null || true"

		log "Writing ${SNIPPET_PATH}..."
		pve_exec "tee '${SNIPPET_PATH}' > /dev/null <<'EOF'
#cloud-config
runcmd:
  - dnf clean all
  - rpm --rebuilddb
  - dnf makecache
  - dnf update -y
  - dnf install -y qemu-guest-agent
  - systemctl enable --now qemu-guest-agent
EOF"
		log "Snippet written"
	fi
fi

if [[ "$SKIP_TEMPLATE" == false ]]; then
	echo
	info "- Cloud-init Template -"

	if pve_check "qm status ${TEMPLATE_ID}"; then
		skip "VM ${TEMPLATE_ID} already exists"
	else
		if pve_check "test -f '${ROCKY_IMG}'"; then
			log "Image already present at ${ROCKY_IMG} — skipping download"
		else
			log "Downloading Rocky Linux 10 image to node (this may take a while)..."
			pve_exec "wget -q --show-progress -O '${ROCKY_IMG}' '${ROCKY_URL}'" ||
				die "Image download failed"
		fi

		log "Creating VM ${TEMPLATE_ID} (${TEMPLATE_NAME})..."
		pve_exec "qm create ${TEMPLATE_ID} --name '${TEMPLATE_NAME}' --memory 2048 --net0 virtio,bridge=vmbr0"

		log "Importing disk to '${STORAGE}'..."
		pve_exec "qm set ${TEMPLATE_ID} --scsi0 ${STORAGE}:0,import-from='${ROCKY_IMG}'"

		log "Configuring cloud-init drive and boot order..."
		pve_exec "qm set ${TEMPLATE_ID} \
      --ide2 ${STORAGE}:cloudinit \
      --boot order=scsi0 \
      --serial0 socket \
      --vga serial0 \
      --agent enabled=1 \
      --cicustom 'vendor=local:snippets/qemu-guest-agent.yml'"

		log "Converting to template..."
		pve_exec "qm template ${TEMPLATE_ID}"

		log "Cleaning up downloaded image..."
		pve_exec "rm -f '${ROCKY_IMG}'"

		log "Template ${TEMPLATE_ID} ready"
	fi
fi

echo
echo -e "${GREEN}  Done${NC}"

if [[ -n "${TOKEN_OUTPUT}" ]]; then
	echo
	warn "Save this token secret — it will not be shown again:"
	echo
	echo -e "${YELLOW}${TOKEN_OUTPUT}${NC}"

	TOKEN_SECRET=$(echo "${TOKEN_OUTPUT}" | grep '^│ value' | sed 's/.*│ //' | sed 's/ │//')
fi

echo
info "terraform.tfvars (copy to terraform/terraform.tfvars):"
echo
cat <<EOF
proxmox_endpoint             = "https://${PVE_HOST}:8006/"
proxmox_api_token            = "${FULL_USER}!${TOKEN_NAME}=${TOKEN_SECRET:-<token secret above>}"
proxmox_insecure             = true
proxmox_ssh_user             = "root"
proxmox_ssh_private_key_path = "~/.ssh/id_ed25519"
EOF
echo

info "Security notes:"
echo
cat <<EOF
- The script does NOT modify SSH settings on your PVE host.
- PVE API user '${FULL_USER}' has the TerraformProv role with limited privileges.
- The API token has privilege separation disabled (full user permissions via API).
- The bpg provider uses root SSH for snippet uploads. This is required because
  the provider writes to /var/lib/vz/snippets/ which is owned by root.
- VM SSH hardening (disable root, key-only auth) is applied by Ansible on the VMs, not the PVE host.
EOF
echo
