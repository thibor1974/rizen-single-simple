#!/usr/bin/env bash
# Open only the ports each side needs on the host.
# - LAN: the API and default ingress (HAProxy on LAN_IP), and the LAN-side DNS.
# - Business bridge (zone libvirt): the cluster's internal load balancer, including
#   22623 (machine config server, which serves node credentials), plus DNS and DHCP,
#   which the libvirt zone already allows.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

lan_zone=$(firewall-cmd --get-zone-of-interface="$LAN_IF" 2>/dev/null || firewall-cmd --get-default-zone)
log "LAN side: zone $lan_zone"
for port in 6443/tcp 80/tcp 443/tcp; do
  firewall-cmd --permanent --zone="$lan_zone" --add-port="$port"
done
firewall-cmd --permanent --zone="$lan_zone" --add-service=dns

log "business side: zone libvirt"
for port in 6443/tcp 22623/tcp 80/tcp 443/tcp; do
  firewall-cmd --permanent --zone=libvirt --add-port="$port"
done

firewall-cmd --reload
firewall-cmd --zone="$lan_zone" --list-all
firewall-cmd --zone=libvirt --list-all
log "firewall configured"
