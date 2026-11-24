#!/usr/bin/env bash
# Install the two dnsmasq instances and verify the cluster records resolve.
# business: DNS and DHCP for the nodes. lan: the cluster names for LAN admins.
# The management network has neither: its addresses are static.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
need_build

conf_dir=/etc/dnsmasq.d/ocp
install -d -m 0755 "$conf_dir"
install -m 0644 "$BUILD_DIR/business.conf" "$BUILD_DIR/lan.conf" "$conf_dir/"
install -m 0644 "$TEMPLATE_DIR/ocp-dnsmasq@.service" /etc/systemd/system/
restorecon -R "$conf_dir" /etc/systemd/system/ocp-dnsmasq@.service

# The earlier layout served the nodes from an instance named "vm".
if systemctl is-enabled ocp-dnsmasq@vm >/dev/null 2>&1; then
  systemctl disable --now ocp-dnsmasq@vm
  log "disabled ocp-dnsmasq@vm from the earlier layout"
fi
rm -f "$conf_dir/vm.conf"

for instance in business lan; do
  dnsmasq --test --conf-file="$conf_dir/$instance.conf"
done

systemctl daemon-reload
systemctl enable ocp-dnsmasq@business ocp-dnsmasq@lan
systemctl restart ocp-dnsmasq@business ocp-dnsmasq@lan

# The host itself resolves through /etc/hosts, so its own resolver settings stay
# untouched. The host is an admin client: it uses the management path, like the LAN.
marker="# managed by rizen8-single"
sed -i "/${marker}\$/d" /etc/hosts
cat >>/etc/hosts <<EOF
$LAN_IP api.$CLUSTER_DOMAIN console-openshift-console.apps.$CLUSTER_DOMAIN oauth-openshift.apps.$CLUSTER_DOMAIN $marker
EOF

expect() {
  local server=$1 name=$2 want=$3 got
  got=$(dig +short +time=2 +tries=2 "@$server" "$name" A)
  [[ $got == "$want" ]] || die "$name via $server returned '$got', expected '$want'"
  log "$name via $server -> $got"
}
expect "$BUSINESS_HOST_IP" "api.$CLUSTER_DOMAIN" "$BUSINESS_HOST_IP"
expect "$BUSINESS_HOST_IP" "api-int.$CLUSTER_DOMAIN" "$BUSINESS_HOST_IP"
expect "$BUSINESS_HOST_IP" "test.apps.$CLUSTER_DOMAIN" "$BUSINESS_HOST_IP"
expect "$BUSINESS_HOST_IP" "master-0.$CLUSTER_DOMAIN" "$MASTER_0_BUSINESS_IP"
expect "$BUSINESS_HOST_IP" "infra-0.$CLUSTER_DOMAIN" "$INFRA_0_BUSINESS_IP"
expect "$LAN_IP" "api.$CLUSTER_DOMAIN" "$LAN_IP"
expect "$LAN_IP" "test.apps.$CLUSTER_DOMAIN" "$LAN_IP"
log "DNS and DHCP are running"
