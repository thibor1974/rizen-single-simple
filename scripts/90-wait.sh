#!/usr/bin/env bash
# Follow the installation to completion and print the cluster state.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

openshift-install agent wait-for bootstrap-complete --dir "$WORK_DIR" --log-level=info
openshift-install agent wait-for install-complete --dir "$WORK_DIR" --log-level=info

export KUBECONFIG="$WORK_DIR/auth/kubeconfig"
oc get nodes -o wide
oc get clusteroperators
log "kubeconfig: $KUBECONFIG"
log "kubeadmin password: $WORK_DIR/auth/kubeadmin-password"
log "console: https://console-openshift-console.apps.$CLUSTER_DOMAIN"
