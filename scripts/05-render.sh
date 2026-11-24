#!/usr/bin/env bash
# Render host configs and cluster manifests into build/ for review. Touches nothing
# on the system.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mkdir -p "$BUILD_DIR"
render "$TEMPLATE_DIR/libvirt-network-business.xml" "$BUILD_DIR/libvirt-network-business.xml"
render "$TEMPLATE_DIR/libvirt-network-mgmt.xml" "$BUILD_DIR/libvirt-network-mgmt.xml"
render "$TEMPLATE_DIR/dnsmasq-business.conf" "$BUILD_DIR/business.conf"
render "$TEMPLATE_DIR/dnsmasq-lan.conf" "$BUILD_DIR/lan.conf"
render "$TEMPLATE_DIR/haproxy.cfg" "$BUILD_DIR/haproxy.cfg"
render "$TEMPLATE_DIR/metallb-config.yaml" "$BUILD_DIR/metallb-config.yaml"
render "$TEMPLATE_DIR/admin-network-policy.yaml" "$BUILD_DIR/admin-network-policy.yaml"
render "$TEMPLATE_DIR/ingress-node-firewall.yaml" "$BUILD_DIR/ingress-node-firewall.yaml"

# Node firewall, one MachineConfig per pool: master (control plane) and worker (the
# infra node only). They differ only in what management offers.
for MC_ROLE in master worker; do
  if [[ $MC_ROLE == master ]]; then
    NFT_MGMT_PORTS="22, 80, 443, 6443"
    NFT_MGMT_DESCRIPTION="SSH 22, API 6443, default ingress and web console 80/443"
  else
    NFT_MGMT_PORTS="22"
    NFT_MGMT_DESCRIPTION="SSH 22 (the infra node runs neither the API nor the default ingress)"
  fi
  export MC_ROLE NFT_MGMT_PORTS NFT_MGMT_DESCRIPTION
  render "$TEMPLATE_DIR/node-firewall.nft" "$BUILD_DIR/node-firewall-${MC_ROLE}.nft"
  NFT_B64=$(base64 <"$BUILD_DIR/node-firewall-${MC_ROLE}.nft" | tr -d '\n')
  export NFT_B64
  render "$TEMPLATE_DIR/99-node-firewall.yaml" "$BUILD_DIR/99-${MC_ROLE}-node-firewall.yaml"
done

# Files from earlier layouts of this project, so build/ only holds current output.
rm -f "$BUILD_DIR/vm.conf" "$BUILD_DIR/libvirt-network.xml" \
  "$BUILD_DIR"/99-*-business-firewall.yaml "$BUILD_DIR"/business-firewall-*.nft

log "rendered configs in $BUILD_DIR"
