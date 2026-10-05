#!/usr/bin/env bash
# =============================================================================
# KijaniKiosk IaC pipeline: Terraform provisions -> inventory -> Ansible configures
#
# Usage:   ./pipeline.sh [multipass|cloud] [log-file]
# Example: ./pipeline.sh multipass pipeline-run1.log
#
#   multipass (default) - VMs run locally in Multipass. IPs come from Terraform
#                         output (which reads them from Multipass) and are
#                         cross-checked against `multipass info`.
#   cloud               - IPs come from Terraform output only.
#
# Requires AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (MinIO credentials) in the
# environment. Exits non-zero if any step fails.
# =============================================================================
set -euo pipefail

PATH_MODE="${1:-multipass}"
LOG_FILE="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"
ANSIBLE_DIR="${SCRIPT_DIR}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory.ini"
KNOWN_HOSTS="${ANSIBLE_DIR}/.known_hosts"
PLAN_FILE="pipeline.tfplan"
MINIO_HEALTH_URL="${MINIO_HEALTH_URL:-http://localhost:9000/minio/health/live}"
REQUIRED_COLLECTIONS=(ansible.posix community.general)

# Send everything to the log file as well as the screen, if one was given
if [ -n "$LOG_FILE" ]; then
    exec > >(tee "$LOG_FILE") 2>&1
fi

# Plain output so the logs are readable
export TF_IN_AUTOMATION=1
export ANSIBLE_NOCOLOR=1
export ANSIBLE_FORCE_COLOR=0

step()  { echo; echo "==== [$(date '+%Y-%m-%d %H:%M:%S')] $* ===="; }
fail()  { echo "PIPELINE FAILED: $*" >&2; exit 1; }
trap 'echo "PIPELINE FAILED at line ${LINENO} (exit code $?)" >&2' ERR

# -----------------------------------------------------------------------------
step "0. Preflight checks (mode: ${PATH_MODE})"
# -----------------------------------------------------------------------------
case "$PATH_MODE" in
    multipass|cloud) ;;
    *) fail "unknown mode '${PATH_MODE}' (use multipass or cloud)" ;;
esac

for cmd in terraform ansible-playbook ansible-galaxy python3 curl; do
    command -v "$cmd" >/dev/null || fail "required command not found: $cmd"
done
if [ "$PATH_MODE" = "multipass" ]; then
    command -v multipass >/dev/null || fail "required command not found: multipass"
fi

[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] \
    || fail "export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (MinIO credentials) first"

curl -sf --max-time 5 "$MINIO_HEALTH_URL" >/dev/null \
    || fail "MinIO state backend not reachable at ${MINIO_HEALTH_URL}"
echo "Tools present, credentials set, MinIO reachable."

# -----------------------------------------------------------------------------
step "1. Terraform: init, plan, apply"
# -----------------------------------------------------------------------------
terraform -chdir="$TF_DIR" init -input=false -no-color
terraform -chdir="$TF_DIR" plan -input=false -no-color -out="$PLAN_FILE"
terraform -chdir="$TF_DIR" apply -input=false -no-color "$PLAN_FILE"
rm -f "${TF_DIR}/${PLAN_FILE}"

# -----------------------------------------------------------------------------
step "2. Write Ansible inventory from Terraform output"
# -----------------------------------------------------------------------------
terraform -chdir="$TF_DIR" output -raw ansible_inventory > "${INVENTORY}.tmp"
mv "${INVENTORY}.tmp" "$INVENTORY"

# "name ip" pairs, read back from the generated inventory
mapfile -t HOSTS < <(awk '/ansible_host=/ { split($2, a, "="); print $1, a[2] }' "$INVENTORY")
[ "${#HOSTS[@]}" -gt 0 ] || fail "inventory has no hosts"
printf '  %s\n' "${HOSTS[@]}"

# -----------------------------------------------------------------------------
step "3. Verify IPs and SSH host keys"
# -----------------------------------------------------------------------------
: > "${KNOWN_HOSTS}.tmp"
for entry in "${HOSTS[@]}"; do
    name="${entry% *}"
    ip="${entry#* }"

    if [ "$PATH_MODE" = "multipass" ]; then
        # Cross-check: Terraform's IP must match what Multipass reports now
        live_ip="$(multipass info "$name" | awk '/IPv4/ { print $2; exit }')"
        [ "$live_ip" = "$ip" ] \
            || fail "${name}: Terraform says ${ip} but Multipass says ${live_ip}"

        # Fetch the host key through Multipass (a channel we already trust),
        # not over the network, so a recreated VM's new key is verified rather
        # than blindly accepted.
        hostkey="$(multipass exec "$name" -- cat /etc/ssh/ssh_host_ed25519_key.pub)"
        echo "${ip} ${hostkey% *}" >> "${KNOWN_HOSTS}.tmp"
        echo "  ${name} ${ip}: IP matches Multipass, host key fetched out-of-band"
    else
        # Cloud path: no out-of-band channel, so trust on first use
        ssh-keyscan -t ed25519 "$ip" >> "${KNOWN_HOSTS}.tmp" 2>/dev/null \
            || fail "${name}: could not read SSH host key from ${ip}"
        echo "  ${name} ${ip}: host key scanned (trust on first use)"
    fi
done
mv "${KNOWN_HOSTS}.tmp" "$KNOWN_HOSTS"

# -----------------------------------------------------------------------------
step "4. Ansible: collections, connectivity, playbook"
# -----------------------------------------------------------------------------
cd "$ANSIBLE_DIR"

for collection in "${REQUIRED_COLLECTIONS[@]}"; do
    if ansible-galaxy collection list "$collection" 2>/dev/null | grep -q "^${collection} "; then
        echo "  collection ${collection} already installed"
    else
        ansible-galaxy collection install -r requirements.yml
        break
    fi
done

ansible kijanikiosk -m ansible.builtin.ping
ansible-playbook kijanikiosk.yml

# -----------------------------------------------------------------------------
step "5. Done"
# -----------------------------------------------------------------------------
echo "Generated inventory (${INVENTORY}):"
cat "$INVENTORY"
echo
echo "PIPELINE SUCCEEDED"
