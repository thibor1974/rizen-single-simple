#!/usr/bin/env bash
# Generate the agent boot ISO. Usage: 70-agent-iso.sh [--force]
# --force moves an earlier install directory aside and starts a new one.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

if [[ -e $WORK_DIR ]]; then
  [[ ${1:-} == --force ]] || die "$WORK_DIR exists (it holds the cluster credentials): pass --force to move it aside"
  backup="${WORK_DIR}.$(date +%Y%m%d-%H%M%S)"
  mv "$WORK_DIR" "$backup"
  log "moved previous install directory to $backup"
fi

install -d -m 0700 "$WORK_DIR"
install -d -m 0755 "$VM_DISK_DIR"

PULL_SECRET=$(jq -c . "$PULL_SECRET_FILE")
SSH_PUB_KEY=$(<"$SSH_PUB_KEY_FILE")
export PULL_SECRET SSH_PUB_KEY

umask 077
render "$TEMPLATE_DIR/install-config.yaml" "$WORK_DIR/install-config.yaml"
render "$TEMPLATE_DIR/agent-config.yaml" "$WORK_DIR/agent-config.yaml"

# The installer consumes its inputs, so keep a copy for later reference.
mkdir "$WORK_DIR/inputs"
cp "$WORK_DIR/install-config.yaml" "$WORK_DIR/agent-config.yaml" "$WORK_DIR/inputs/"

log "creating the agent ISO (first run downloads the RHCOS image)"
openshift-install agent create image --dir "$WORK_DIR"

install -m 0644 "$WORK_DIR/agent.x86_64.iso" "$AGENT_ISO"
restorecon -R "$VM_DISK_DIR"
log "ISO ready: $AGENT_ISO"
warn "bootstrap certificates in this ISO expire after 24 hours: boot the nodes today"
