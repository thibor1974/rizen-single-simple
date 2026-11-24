#!/usr/bin/env bash
# Install the Ingress Node Firewall Operator and deny SSH, the API and the default
# ingress on the business NIC, except from the cluster itself. Safe to re-run.
#
# The firewall is stateless and drops packets before anything else sees them, so a
# mistake could cut the nodes off from the API. After applying it, this script checks
# the cluster's own paths and removes the rules again if one of them fails.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
need_build

[[ -f $BUILD_DIR/ingress-node-firewall.yaml ]] || die "$BUILD_DIR/ingress-node-firewall.yaml not found: run scripts/05-render.sh again"
export KUBECONFIG="$WORK_DIR/auth/kubeconfig"
[[ -r $KUBECONFIG ]] || die "$KUBECONFIG not found: finish the install with scripts/90-wait.sh first"
oc get node infra-0 -o jsonpath='{.metadata.labels}' | grep -q 'node-role.kubernetes.io/infra' ||
  die "infra-0 has no infra role yet: run scripts/95-post-install.sh first"

ns=openshift-ingress-node-firewall
masters=("$MASTER_0_BUSINESS_IP" "$MASTER_1_BUSINESS_IP" "$MASTER_2_BUSINESS_IP")

# A spare address on business, not in any node, MetalLB or EgressIP range, used to
# play an outside business client from the host.
probe_octet=254
for var in MASTER_0_OCTET MASTER_1_OCTET MASTER_2_OCTET INFRA_0_OCTET; do
  ((${!var} != probe_octet)) || die "$var is $probe_octet, which this script uses as a test address"
done
if ((probe_octet >= BUSINESS_METALLB_FIRST_OCTET && probe_octet <= BUSINESS_METALLB_LAST_OCTET)) ||
  ((probe_octet >= BUSINESS_EGRESS_FIRST_OCTET && probe_octet <= BUSINESS_EGRESS_LAST_OCTET)); then
  die "${BUSINESS_SUBNET}.$probe_octet is inside a reserved business range"
fi
probe_ip="${BUSINESS_SUBNET}.${probe_octet}"

# Cluster paths that must keep working: the internal LB's own health checks reach the
# masters from the host's business address (an allowed source), and the nodes stay Ready.
cluster_paths_ok() {
  local ip
  for ip in "${masters[@]}"; do
    [[ $(curl -sk --max-time 5 "https://$ip:6443/readyz") == ok ]] || {
      warn "API on $ip does not answer the internal load balancer"
      return 1
    }
  done
  if oc get nodes --no-headers | awk '$2 !~ /^Ready/' | grep -q .; then
    warn "a node is not Ready"
    return 1
  fi
}

rollback() {
  warn "rolling back: deleting the IngressNodeFirewall rules"
  oc delete ingressnodefirewall business-masters business-infra --ignore-not-found
  die "$1"
}

log "checking that the Ingress Node Firewall Operator is in the catalog"
oc -n openshift-marketplace get packagemanifest ingress-node-firewall >/dev/null ||
  die "package ingress-node-firewall not found in the catalog (disconnected cluster?)"

log "installing the Ingress Node Firewall Operator"
oc apply -f "$TEMPLATE_DIR/ingress-node-firewall-operator.yaml"
wait_for "the Ingress Node Firewall Operator" csv_succeeded "$ns" ingress-node-firewall

cluster_paths_ok || die "the cluster is not healthy before any rule is applied: fix that first"

log "labelling the nodes that run the firewall daemon"
oc label nodes --all ingress-node-firewall/enabled=true --overwrite >/dev/null

log "applying the firewall config and rules"
wait_for "the Ingress Node Firewall API to accept the rules" oc apply -f "$BUILD_DIR/ingress-node-firewall.yaml"

# The daemon needs to run on every node. infra-0 is tainted; if the daemon does not
# tolerate that, infra-0 stays protected by nftables only.
wait_for "the firewall daemon" bash -c "oc -n $ns get daemonset -o name | grep -q ."
sleep 30
read -r desired ready < <(oc -n "$ns" get daemonset -o jsonpath='{range .items[*]}{.status.desiredNumberScheduled}{" "}{.status.numberReady}{"\n"}{end}' | head -1) || true
desired=${desired:-0} ready=${ready:-0}
log "firewall daemon: $ready of $desired nodes ready"
if ((desired < 4)); then
  warn "the daemon does not run on every node (infra-0's taint?): infra-0 is covered by nftables only"
  warn "check: oc -n $ns get daemonset -o yaml | grep -A10 tolerations"
fi

# Kubelets that lost the API show up as NotReady after about 40 s.
log "checking that the cluster still works in 60 s (rolls back on failure)"
sleep 60
cluster_paths_ok || rollback "the rules cut a cluster path"
log "cluster paths are fine"

# Play an outside business client: a temporary extra address on the host's business
# bridge, which is neither a node nor the internal load balancer.
log "checking that an outside business client is refused (from $probe_ip)"
ip addr add "$probe_ip/24" dev "$BUSINESS_BRIDGE"
trap 'ip addr del "$probe_ip/24" dev "$BUSINESS_BRIDGE" 2>/dev/null || true' EXIT
# connects URL: true if a TCP connection from probe_ip was established, whatever the
# protocol said afterwards (time_connect stays 0 when the SYN went unanswered).
connects() {
  local t
  t=$(curl -sk -o /dev/null --connect-timeout 3 --max-time 6 --interface "$probe_ip" \
    -w '%{time_connect}' "$1" 2>/dev/null) || true
  [[ -n $t && ! $t =~ ^0(\.0+)?$ ]]
}
failed=0
targets=()
for ip in "${masters[@]}"; do
  targets+=("http://$ip:22" "https://$ip:443" "https://$ip:6443")
done
targets+=("http://$INFRA_0_BUSINESS_IP:22")
for url in "${targets[@]}"; do
  if connects "$url"; then
    warn "${url#*://} accepted a connection from a business client"
    failed=1
  fi
done
((failed == 0)) || die "management ports are reachable from business: check oc get ingressnodefirewallnodestates -A"
log "SSH, API and default ingress are refused from business"

oc get ingressnodefirewallnodestates -A 2>/dev/null || true
log "done. Drops are counted in the ingressnodefirewall_node_packet_deny_total metric (Observe > Metrics in the console)"
