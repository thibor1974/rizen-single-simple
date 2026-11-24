#!/usr/bin/env bash
# Post-install: node roles, MetalLB and EgressIP on the business network, then the
# AdminNetworkPolicy that keeps application pods off the node addresses.
# Safe to re-run; re-run it after installing an operator in a new platform namespace.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
need_build

for f in metallb-config.yaml admin-network-policy.yaml; do
  [[ -f $BUILD_DIR/$f ]] || die "$BUILD_DIR/$f not found: run scripts/05-render.sh again"
done
export KUBECONFIG="$WORK_DIR/auth/kubeconfig"
[[ -r $KUBECONFIG ]] || die "$KUBECONFIG not found: finish the install with scripts/90-wait.sh first"

oc get node infra-0 >/dev/null || die "node infra-0 not found: has it joined the cluster?"

# The whole design depends on the node IPs being on business.
log "checking that every node IP is on the business network"
while read -r node ip; do
  [[ $ip == "${BUSINESS_SUBNET}."* ]] || die "node $node has InternalIP $ip, expected one in $BUSINESS_CIDR"
done < <(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

# With one worker the installer taints the masters NoSchedule. Workloads run on the
# masters here, and the infra node is reserved for business ingress and egress, so open
# the masters first and taint the infra node second: pods already on it move away.
log "making the masters schedulable"
oc patch scheduler cluster --type=merge -p '{"spec":{"mastersSchedulable":true}}'

log "marking infra-0 as the infra node (role label, taints, egress-assignable)"
oc label node infra-0 node-role.kubernetes.io/infra="" --overwrite
oc adm taint nodes infra-0 node-role.kubernetes.io/infra=reserved:NoSchedule --overwrite
oc adm taint nodes infra-0 node-role.kubernetes.io/infra=reserved:NoExecute --overwrite
oc label node infra-0 k8s.ovn.org/egress-assignable="" --overwrite
oc label nodes -l node-role.kubernetes.io/master k8s.ovn.org/egress-assignable- >/dev/null

log "installing the MetalLB operator"
oc apply -f "$TEMPLATE_DIR/metallb-operator.yaml"
wait_for "the MetalLB operator" csv_succeeded metallb-system metallb-operator

log "configuring MetalLB (speaker on infra-0 only, announcing on br-ex)"
wait_for "MetalLB to accept its configuration" oc apply -f "$BUILD_DIR/metallb-config.yaml"
wait_for "the speaker daemonset" oc -n metallb-system get daemonset speaker
oc -n metallb-system rollout status daemonset/speaker --timeout=10m

# Platform namespaces are exempt from the AdminNetworkPolicy: they legitimately reach
# node addresses (monitoring, API servers to etcd, network diagnostics...). Project
# admins cannot label namespaces, so applications cannot exempt themselves.
log "labelling platform namespaces node-access/platform=true"
mapfile -t platform_namespaces < <(oc get namespaces -o name | sed 's|^namespace/||' |
  grep -E '^(openshift|openshift-.*|kube-system|kube-public|kube-node-lease|metallb-system)$')
((${#platform_namespaces[@]} > 0)) || die "no platform namespaces found"
oc label namespace "${platform_namespaces[@]}" node-access/platform=true --overwrite >/dev/null
log "${#platform_namespaces[@]} platform namespaces labelled"

log "denying application pods access to the node addresses (AdminNetworkPolicy)"
oc get crd adminnetworkpolicies.policy.networking.k8s.io >/dev/null ||
  die "this cluster has no AdminNetworkPolicy API (needs OpenShift 4.16 or later)"
oc apply -f "$BUILD_DIR/admin-network-policy.yaml"

log "default ingress: $(oc -n openshift-ingress get pods -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{end}')"
log "MetalLB pool: $BUSINESS_METALLB_RANGE (announced by infra-0)"
log "reserved for EgressIP objects: $BUSINESS_EGRESS_RANGE (hosted by infra-0)"
log "application pods denied: $(tr '\n' ' ' <<<"$ANP_NODE_CIDRS")(API on the masters allowed)"
