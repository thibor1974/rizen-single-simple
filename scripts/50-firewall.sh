#!/usr/bin/env bash
# Open only the ports each side needs on the host.
# - LAN: the admin front end (API, default ingress) and the LAN-side DNS.
# - LAN -> management network (routed): SSH, API and default ingress to the nodes'
#   management addresses, for admins who use them directly. Nothing the other way.
# - Business bridge (zone libvirt): the cluster's internal load balancer, including
#   22623 (machine config server, which serves node credentials), plus DNS and DHCP,
#   which the libvirt zone already allows. Host SSH is removed from that zone.
# - Management bridge (zone ocp-mgmt): nodes may not open connections to the host.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

# The host routes LAN <-> management. libvirt's NAT network turns this on as well,
# but management must not depend on it.
echo 'net.ipv4.ip_forward = 1' >/etc/sysctl.d/90-ocp-forwarding.conf
sysctl -q -p /etc/sysctl.d/90-ocp-forwarding.conf

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
# The libvirt zone allows SSH to the host by default. Host SSH is management, so it
# is not offered on the business side. This also applies to other libvirt networks
# in that zone, such as "default".
for service in ssh tftp; do
  if firewall-cmd --permanent --zone=libvirt --query-service="$service" >/dev/null; then
    firewall-cmd --permanent --zone=libvirt --remove-service="$service"
  fi
done

# Management: a zone with no services, so connections from the nodes to the host are
# refused (replies to the host's own SSH and HAProxy connections still pass).
log "management side: zone ocp-mgmt on $MGMT_BRIDGE"
if ! firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -qx ocp-mgmt; then
  firewall-cmd --permanent --new-zone=ocp-mgmt
fi
firewall-cmd --permanent --zone=ocp-mgmt --change-interface="$MGMT_BRIDGE"

# Forwarding LAN -> management: admin ports only. The node firewall narrows it per
# role (the infra node answers SSH only). firewalld has no policy for the reverse
# direction, so nodes cannot open connections to the LAN; replies are allowed.
log "routing: $lan_zone -> ocp-mgmt for SSH, API and default ingress"
if ! firewall-cmd --permanent --get-policies | tr ' ' '\n' | grep -qx ocp-mgmt-admin; then
  firewall-cmd --permanent --new-policy=ocp-mgmt-admin
fi
firewall-cmd --permanent --policy=ocp-mgmt-admin --add-ingress-zone="$lan_zone"
firewall-cmd --permanent --policy=ocp-mgmt-admin --add-egress-zone=ocp-mgmt
firewall-cmd --permanent --policy=ocp-mgmt-admin --set-target=REJECT
for port in 22/tcp 6443/tcp 80/tcp 443/tcp; do
  firewall-cmd --permanent --policy=ocp-mgmt-admin --add-port="$port"
done
firewall-cmd --permanent --policy=ocp-mgmt-admin --add-protocol=icmp

firewall-cmd --reload
mgmt_zone=$(firewall-cmd --get-zone-of-interface="$MGMT_BRIDGE" 2>/dev/null || true)
[[ $mgmt_zone == ocp-mgmt ]] || die "$MGMT_BRIDGE is in zone '${mgmt_zone:-none}', expected ocp-mgmt (is the network up? run scripts/20-network.sh)"
firewall-cmd --zone="$lan_zone" --list-all
firewall-cmd --zone=libvirt --list-all
firewall-cmd --zone=ocp-mgmt --list-all
firewall-cmd --policy=ocp-mgmt-admin --list-all
log "firewall configured"
log "LAN clients that use the management addresses directly need a route: ${MGMT_CIDR} via ${LAN_IP}"
