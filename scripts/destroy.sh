#!/usr/bin/env bash
# Delete the three cluster VMs, their disks and the agent ISO, after typed
# confirmation. Host services, the VM network and WORK_DIR are left in place.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

echo "This permanently deletes VMs ${CLUSTER_NAME}-master-{0,1,2} and their disks in $VM_DISK_DIR."
read -r -p "Type the cluster name ($CLUSTER_NAME) to confirm: " answer
[[ $answer == "$CLUSTER_NAME" ]] || die "confirmation did not match, nothing was changed"

for i in 0 1 2; do
  name="${CLUSTER_NAME}-master-${i}"
  if virsh dominfo "$name" >/dev/null 2>&1; then
    if [[ $(virsh domstate "$name") == running ]]; then virsh destroy "$name"; fi
    virsh undefine "$name" --nvram 2>/dev/null || virsh undefine "$name"
    log "removed VM $name"
  fi
  rm -f -- "${VM_DISK_DIR}/${name}.qcow2"
done
rm -f -- "$AGENT_ISO"
log "done: run scripts/70-agent-iso.sh --force before reinstalling"
