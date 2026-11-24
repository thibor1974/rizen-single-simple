#!/usr/bin/env bash
# Install and start HAProxy for the API, machine config server and ingress.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
need_build

# HAProxy on these ports is denied by SELinux without this boolean.
setsebool -P haproxy_connect_any 1

# Lets HAProxy bind the bridge address at boot even if libvirt is not up yet.
echo 'net.ipv4.ip_nonlocal_bind = 1' >/etc/sysctl.d/90-ocp-loadbalancer.conf
sysctl -q -p /etc/sysctl.d/90-ocp-loadbalancer.conf

[[ -f /etc/haproxy/haproxy.cfg.orig ]] || cp -p /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.orig
haproxy -c -f "$BUILD_DIR/haproxy.cfg"
install -m 0644 "$BUILD_DIR/haproxy.cfg" /etc/haproxy/haproxy.cfg
restorecon /etc/haproxy/haproxy.cfg

systemctl enable haproxy
systemctl restart haproxy
log "HAProxy is running (backends stay down until the nodes are installed)"
