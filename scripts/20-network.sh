#!/usr/bin/env bash
# Define and start the libvirt business (NAT, machine network) and management
# (routed from the LAN for admin ports only, see scripts/50-firewall.sh) networks.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
need_build

define_network() {
  local name=$1 xml=$2
  virsh net-define "$xml"
  virsh net-autostart "$name"
  if [[ $(virsh net-info "$name" | awk '/^Active:/ {print $2}') != yes ]]; then
    virsh net-start "$name"
  else
    warn "network $name was already running: any definition change applies after it restarts"
  fi
}

# The earlier layout had management as a NAT network named "ocp" on the same subnet.
if [[ $MGMT_NET_NAME != ocp && $BUSINESS_NET_NAME != ocp ]] && virsh net-info ocp >/dev/null 2>&1; then
  die "libvirt network 'ocp' from the earlier layout still exists: after scripts/destroy.sh, remove it with 'virsh net-destroy ocp; virsh net-undefine ocp'"
fi

define_network "$BUSINESS_NET_NAME" "$BUILD_DIR/libvirt-network-business.xml"
define_network "$MGMT_NET_NAME" "$BUILD_DIR/libvirt-network-mgmt.xml"

ip -4 addr show dev "$BUSINESS_BRIDGE"
ip -4 addr show dev "$MGMT_BRIDGE"
log "network $BUSINESS_NET_NAME is up on $BUSINESS_BRIDGE (machine network, NAT to the LAN)"
log "network $MGMT_NET_NAME is up on $MGMT_BRIDGE (admin access only, routed from the LAN by scripts/50-firewall.sh)"
