#!/usr/bin/env bash
# Define and start the libvirt business network (NAT, machine network).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
need_build

virsh net-define "$BUILD_DIR/libvirt-network-business.xml"
virsh net-autostart "$BUSINESS_NET_NAME"
if [[ $(virsh net-info "$BUSINESS_NET_NAME" | awk '/^Active:/ {print $2}') != yes ]]; then
  virsh net-start "$BUSINESS_NET_NAME"
else
  warn "network $BUSINESS_NET_NAME was already running: any definition change applies after it restarts"
fi

ip -4 addr show dev "$BUSINESS_BRIDGE"
log "network $BUSINESS_NET_NAME is up on $BUSINESS_BRIDGE (machine network, NAT to the LAN)"
