#!/usr/bin/env bash
# Install host packages and start firewalld and the libvirt daemons.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

log "installing packages"
dnf install -y qemu-kvm qemu-img libvirt virt-install \
  dnsmasq haproxy firewalld policycoreutils-python-utils \
  nmstate jq gettext tar curl bind-utils iproute

# firewalld first: the VM network is attached to its "libvirt" zone.
systemctl enable --now firewalld
firewall-cmd --reload

log "enabling modular libvirt daemons"
for driver in qemu network nodedev nwfilter secret storage interface; do
  systemctl unmask "virt${driver}d.service" "virt${driver}d"{,-ro,-admin}.socket
  systemctl enable "virt${driver}d.service" "virt${driver}d"{,-ro,-admin}.socket
  systemctl start "virt${driver}d"{,-ro,-admin}.socket
done

virt-host-validate qemu || warn "virt-host-validate reported issues, review the output above"
log "packages ready"
