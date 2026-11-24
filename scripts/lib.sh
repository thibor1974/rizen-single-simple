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

# range_to_cidrs PREFIX FIRST LAST: the smallest set of CIDRs covering
# PREFIX.FIRST-PREFIX.LAST, one per line (PREFIX is three octets).
range_to_cidrs() {
  local prefix=$1 a=$2 b=$3 size bits
  while ((a <= b)); do
    size=1 bits=32
    while ((a % (size * 2) == 0 && a + size * 2 - 1 <= b)); do
      size=$((size * 2)) bits=$((bits - 1))
    done
    printf '%s.%s/%s\n' "$prefix" "$a" "$bits"
    a=$((a + size))
  done
}

# yaml_list INDENT: turn stdin lines into "- item" lines indented by INDENT spaces.
yaml_list() { sed "s/^/$(printf '%*s' "$1" '')- /"; }

[[ -r $ENV_FILE ]] || die "$ENV_FILE not found: copy cluster.env.example to cluster.env and edit it"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"

for var in CLUSTER_NAME BASE_DOMAIN OCP_VERSION LAN_IF LAN_IP UPSTREAM_DNS \
  BUSINESS_SUBNET BUSINESS_NET_NAME BUSINESS_BRIDGE MGMT_SUBNET MGMT_NET_NAME MGMT_BRIDGE \
  MASTER_0_OCTET MASTER_1_OCTET MASTER_2_OCTET INFRA_0_OCTET \
  MASTER_0_BUSINESS_MAC MASTER_1_BUSINESS_MAC MASTER_2_BUSINESS_MAC INFRA_0_BUSINESS_MAC \
  MASTER_0_MGMT_MAC MASTER_1_MGMT_MAC MASTER_2_MGMT_MAC INFRA_0_MGMT_MAC \
  BUSINESS_METALLB_FIRST_OCTET BUSINESS_METALLB_LAST_OCTET \
  BUSINESS_EGRESS_FIRST_OCTET BUSINESS_EGRESS_LAST_OCTET \
  CLUSTER_NETWORK_CIDR CLUSTER_NETWORK_HOST_PREFIX SERVICE_NETWORK_CIDR \
  VM_VCPUS VM_MEM_GIB VM_DISK_GIB INFRA_VCPUS INFRA_MEM_GIB INFRA_DISK_GIB \
  VM_DISK_DIR PULL_SECRET_FILE SSH_PUB_KEY_FILE WORK_DIR; do
  [[ -n ${!var:-} && ${!var} != CHANGE_ME ]] || die "$var is not set in $ENV_FILE (cluster.env.example lists every setting)"
done

[[ $LAN_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "LAN_IP must be an IPv4 address"
for var in BUSINESS_SUBNET MGMT_SUBNET; do
  [[ ${!var} =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "$var must be three octets, e.g. 192.168.127"
done
[[ $BUSINESS_SUBNET != "$MGMT_SUBNET" ]] || die "BUSINESS_SUBNET and MGMT_SUBNET must differ"
((${#BUSINESS_BRIDGE} <= 15)) || die "BUSINESS_BRIDGE must be 15 characters or fewer"
((${#MGMT_BRIDGE} <= 15)) || die "MGMT_BRIDGE must be 15 characters or fewer"

for var in BUSINESS_METALLB_FIRST_OCTET BUSINESS_METALLB_LAST_OCTET BUSINESS_EGRESS_FIRST_OCTET BUSINESS_EGRESS_LAST_OCTET; do
  [[ ${!var} =~ ^[1-9][0-9]*$ ]] && ((${!var} >= 2 && ${!var} <= 254)) || die "$var must be a number from 2 to 254"
done
((BUSINESS_METALLB_FIRST_OCTET <= BUSINESS_METALLB_LAST_OCTET)) || die "the BUSINESS_METALLB range is reversed"
((BUSINESS_EGRESS_FIRST_OCTET <= BUSINESS_EGRESS_LAST_OCTET)) || die "the BUSINESS_EGRESS range is reversed"
((BUSINESS_METALLB_LAST_OCTET < BUSINESS_EGRESS_FIRST_OCTET || BUSINESS_EGRESS_LAST_OCTET < BUSINESS_METALLB_FIRST_OCTET)) ||
  die "the BUSINESS_METALLB and BUSINESS_EGRESS ranges overlap"
# .1 is the host on both networks.
for var in MASTER_0_OCTET MASTER_1_OCTET MASTER_2_OCTET INFRA_0_OCTET; do
  [[ ${!var} =~ ^[1-9][0-9]*$ ]] && ((${!var} >= 2 && ${!var} <= 254)) || die "$var must be a number from 2 to 254"
  if ((${!var} >= BUSINESS_METALLB_FIRST_OCTET && ${!var} <= BUSINESS_METALLB_LAST_OCTET)) ||
    ((${!var} >= BUSINESS_EGRESS_FIRST_OCTET && ${!var} <= BUSINESS_EGRESS_LAST_OCTET)); then
    die "$var falls inside a reserved business range"
  fi
done
[[ $(printf '%s\n' "$MASTER_0_OCTET" "$MASTER_1_OCTET" "$MASTER_2_OCTET" "$INFRA_0_OCTET" | sort -u | wc -l) -eq 4 ]] ||
  die "MASTER_n_OCTET and INFRA_0_OCTET must all differ"

CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"

# Business: the machine network. The host is gateway, DNS, DHCP and internal LB.
BUSINESS_HOST_IP="${BUSINESS_SUBNET}.1"
BUSINESS_CIDR="${BUSINESS_SUBNET}.0/24"
MACHINE_NETWORK_CIDR="$BUSINESS_CIDR"
MASTER_0_BUSINESS_IP="${BUSINESS_SUBNET}.${MASTER_0_OCTET}"
MASTER_1_BUSINESS_IP="${BUSINESS_SUBNET}.${MASTER_1_OCTET}"
MASTER_2_BUSINESS_IP="${BUSINESS_SUBNET}.${MASTER_2_OCTET}"
INFRA_0_BUSINESS_IP="${BUSINESS_SUBNET}.${INFRA_0_OCTET}"
BUSINESS_METALLB_RANGE="${BUSINESS_SUBNET}.${BUSINESS_METALLB_FIRST_OCTET}-${BUSINESS_SUBNET}.${BUSINESS_METALLB_LAST_OCTET}"
BUSINESS_EGRESS_RANGE="${BUSINESS_SUBNET}.${BUSINESS_EGRESS_FIRST_OCTET}-${BUSINESS_SUBNET}.${BUSINESS_EGRESS_LAST_OCTET}"

# Management: admin access only. The host is the front end for LAN admins.
MGMT_HOST_IP="${MGMT_SUBNET}.1"
MGMT_CIDR="${MGMT_SUBNET}.0/24"
# Policy routing for management replies (templates/agent-config.yaml): a routing table
# of its own, consulted for traffic sourced from the management address, before the
# main table (priority 32766).
MGMT_ROUTE_TABLE=126
MGMT_RULE_PRIORITY=1000
MASTER_0_MGMT_IP="${MGMT_SUBNET}.${MASTER_0_OCTET}"
MASTER_1_MGMT_IP="${MGMT_SUBNET}.${MASTER_1_OCTET}"
MASTER_2_MGMT_IP="${MGMT_SUBNET}.${MASTER_2_OCTET}"
INFRA_0_MGMT_IP="${MGMT_SUBNET}.${INFRA_0_OCTET}"

# Node firewall (templates/node-firewall.nft): the only sources allowed to open
# connections to a node on the business NIC. Nodes, and the host as internal LB.
NFT_CLUSTER_SOURCES="$MASTER_0_BUSINESS_IP, $MASTER_1_BUSINESS_IP, $MASTER_2_BUSINESS_IP, $INFRA_0_BUSINESS_IP, $BUSINESS_HOST_IP"

# AdminNetworkPolicy (templates/admin-network-policy.yaml), rendered as YAML lists.
# API: the masters' business addresses, which back the kubernetes Service.
ANP_API_CIDRS_YAML=$(printf '%s/32\n' "$MASTER_0_BUSINESS_IP" "$MASTER_1_BUSINESS_IP" "$MASTER_2_BUSINESS_IP" | yaml_list 12)
# Everything a node owns: business node addresses, the EgressIP addresses hosted on
# infra-0, and the whole management network.
ANP_NODE_CIDRS=$(
  printf '%s/32\n' "$MASTER_0_BUSINESS_IP" "$MASTER_1_BUSINESS_IP" "$MASTER_2_BUSINESS_IP" "$INFRA_0_BUSINESS_IP"
  range_to_cidrs "$BUSINESS_SUBNET" "$BUSINESS_EGRESS_FIRST_OCTET" "$BUSINESS_EGRESS_LAST_OCTET"
  printf '%s\n' "$MGMT_CIDR"
)
(($(wc -l <<<"$ANP_NODE_CIDRS") <= 25)) ||
  die "the node addresses need more than 25 CIDRs (the AdminNetworkPolicy limit): align the BUSINESS_EGRESS range on a power of two"
ANP_NODE_CIDRS_YAML=$(yaml_list 12 <<<"$ANP_NODE_CIDRS")
ANP_LB_CIDRS_YAML=$(printf '%s/32\n' "$BUSINESS_HOST_IP" | yaml_list 12)

# Ingress Node Firewall (templates/ingress-node-firewall.yaml): the cluster's own
# sources on business, which keep access to every port.
INF_CLUSTER_CIDRS_YAML=$(printf '%s/32\n' "$MASTER_0_BUSINESS_IP" "$MASTER_1_BUSINESS_IP" \
  "$MASTER_2_BUSINESS_IP" "$INFRA_0_BUSINESS_IP" "$BUSINESS_HOST_IP" | yaml_list 8)

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
