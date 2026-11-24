#!/usr/bin/env bash
# Render host configs and cluster manifests into build/ for review. Touches nothing
# on the system.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mkdir -p "$BUILD_DIR"
render "$TEMPLATE_DIR/libvirt-network-business.xml" "$BUILD_DIR/libvirt-network-business.xml"
render "$TEMPLATE_DIR/dnsmasq-business.conf" "$BUILD_DIR/business.conf"
render "$TEMPLATE_DIR/dnsmasq-lan.conf" "$BUILD_DIR/lan.conf"
render "$TEMPLATE_DIR/haproxy.cfg" "$BUILD_DIR/haproxy.cfg"
render "$TEMPLATE_DIR/metallb-config.yaml" "$BUILD_DIR/metallb-config.yaml"

log "rendered configs in $BUILD_DIR"
