#!/usr/bin/env bash
# Post-install: install MetalLB and give it the business address pool. Safe to re-run.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
need_build

[[ -f $BUILD_DIR/metallb-config.yaml ]] || die "$BUILD_DIR/metallb-config.yaml not found: run scripts/05-render.sh again"
export KUBECONFIG="$WORK_DIR/auth/kubeconfig"
[[ -r $KUBECONFIG ]] || die "$KUBECONFIG not found: finish the install with scripts/90-wait.sh first"

log "checking that every node IP is on the business network"
while read -r node ip; do
  [[ $ip == "${BUSINESS_SUBNET}."* ]] || die "node $node has InternalIP $ip, expected one in $BUSINESS_CIDR"
done < <(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

log "installing the MetalLB operator"
oc apply -f "$TEMPLATE_DIR/metallb-operator.yaml"
wait_for "the MetalLB operator" csv_succeeded metallb-system metallb-operator

log "configuring MetalLB (speakers on every node, announcing on br-ex)"
wait_for "MetalLB to accept its configuration" oc apply -f "$BUILD_DIR/metallb-config.yaml"
wait_for "the speaker daemonset" oc -n metallb-system get daemonset speaker
oc -n metallb-system rollout status daemonset/speaker --timeout=10m

log "MetalLB pool: $BUSINESS_METALLB_RANGE"
