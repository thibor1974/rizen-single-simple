#!/usr/bin/env bash
# Shared setup: strict mode, cluster.env loading, derived values, helpers.
# shellcheck disable=SC2034  # derived values are used by templates and callers
set -Eeuo pipefail
trap 'echo "ERROR: ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
TEMPLATE_DIR="$ROOT_DIR/templates"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/cluster.env}"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() {
  printf 'FATAL: %s\n' "$*" >&2
  exit 1
}

need_root() { [[ $EUID -eq 0 ]] || die "run this script as root"; }

[[ -r $ENV_FILE ]] || die "$ENV_FILE not found: copy cluster.env.example to cluster.env and edit it"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"

for var in CLUSTER_NAME BASE_DOMAIN OCP_VERSION LAN_IF LAN_IP UPSTREAM_DNS \
  BUSINESS_SUBNET BUSINESS_NET_NAME BUSINESS_BRIDGE \
  MASTER_0_OCTET MASTER_1_OCTET MASTER_2_OCTET MASTER_0_MAC MASTER_1_MAC MASTER_2_MAC \
  BUSINESS_METALLB_FIRST_OCTET BUSINESS_METALLB_LAST_OCTET \
  CLUSTER_NETWORK_CIDR CLUSTER_NETWORK_HOST_PREFIX SERVICE_NETWORK_CIDR \
  VM_VCPUS VM_MEM_GIB VM_DISK_GIB VM_DISK_DIR PULL_SECRET_FILE SSH_PUB_KEY_FILE WORK_DIR; do
  [[ -n ${!var:-} && ${!var} != CHANGE_ME ]] || die "$var is not set in $ENV_FILE (cluster.env.example lists every setting)"
done

[[ $LAN_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "LAN_IP must be an IPv4 address"
[[ $BUSINESS_SUBNET =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "BUSINESS_SUBNET must be three octets, e.g. 192.168.127"
((${#BUSINESS_BRIDGE} <= 15)) || die "BUSINESS_BRIDGE must be 15 characters or fewer"

for var in BUSINESS_METALLB_FIRST_OCTET BUSINESS_METALLB_LAST_OCTET; do
  [[ ${!var} =~ ^[1-9][0-9]*$ ]] && ((${!var} >= 2 && ${!var} <= 254)) || die "$var must be a number from 2 to 254"
done
((BUSINESS_METALLB_FIRST_OCTET <= BUSINESS_METALLB_LAST_OCTET)) || die "the BUSINESS_METALLB range is reversed"
# .1 is the host.
for var in MASTER_0_OCTET MASTER_1_OCTET MASTER_2_OCTET; do
  [[ ${!var} =~ ^[1-9][0-9]*$ ]] && ((${!var} >= 2 && ${!var} <= 254)) || die "$var must be a number from 2 to 254"
  if ((${!var} >= BUSINESS_METALLB_FIRST_OCTET && ${!var} <= BUSINESS_METALLB_LAST_OCTET)); then
    die "$var falls inside the BUSINESS_METALLB range"
  fi
done
[[ $(printf '%s\n' "$MASTER_0_OCTET" "$MASTER_1_OCTET" "$MASTER_2_OCTET" | sort -u | wc -l) -eq 3 ]] ||
  die "MASTER_n_OCTET must all differ"

CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"

# Business: the only network, and the machine network. The host is gateway, DNS,
# DHCP and load balancer.
BUSINESS_HOST_IP="${BUSINESS_SUBNET}.1"
BUSINESS_CIDR="${BUSINESS_SUBNET}.0/24"
MACHINE_NETWORK_CIDR="$BUSINESS_CIDR"
MASTER_0_IP="${BUSINESS_SUBNET}.${MASTER_0_OCTET}"
MASTER_1_IP="${BUSINESS_SUBNET}.${MASTER_1_OCTET}"
MASTER_2_IP="${BUSINESS_SUBNET}.${MASTER_2_OCTET}"
BUSINESS_METALLB_RANGE="${BUSINESS_SUBNET}.${BUSINESS_METALLB_FIRST_OCTET}-${BUSINESS_SUBNET}.${BUSINESS_METALLB_LAST_OCTET}"

AGENT_ISO="${VM_DISK_DIR}/${CLUSTER_NAME}-agent.x86_64.iso"
set +a

# Render a template, substituting only the ${VARS} it names, and fail on any
# that are undefined so a typo cannot produce a silently blank config value.
render() {
  local src=$1 dst=$2 vars v name
  vars=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$src" | sort -u | tr '\n' ' ' || true)
  for v in $vars; do
    name=${v#\$\{}
    name=${name%\}}
    [[ -n ${!name+x} ]] || die "$src references undefined variable $name"
  done
  envsubst "$vars" <"$src" >"$dst"
}

# wait_for WHAT CMD...: retry CMD every 10 s for up to 10 minutes. Operators (OLM)
# and their webhooks come up asynchronously.
wait_for() {
  local what=$1 attempt
  shift
  for ((attempt = 0; attempt < 60; attempt++)); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 10
  done
  die "timed out waiting for $what"
}

# csv_succeeded NAMESPACE PACKAGE: the operator's ClusterServiceVersion is installed.
csv_succeeded() {
  [[ $(oc -n "$1" get csv -l "operators.coreos.com/$2.$1" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null) == Succeeded ]]
}

need_build() {
  [[ -f $BUILD_DIR/haproxy.cfg ]] || die "no rendered configs: run scripts/05-render.sh first"
}
