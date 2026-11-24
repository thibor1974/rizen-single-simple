#!/usr/bin/env bash
# Create and boot the four VMs, each with a management NIC (enp1s0, admin access)
# and a business NIC (enp2s0, machine network). Boot order is disk then CD-ROM: blank disks fall
# through to the agent ISO, and installed disks boot directly afterwards.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

[[ -f $AGENT_ISO ]] || die "$AGENT_ISO not found: run scripts/70-agent-iso.sh first"

for name in "${CLUSTER_NAME}"-master-{0,1,2} "${CLUSTER_NAME}-infra-0"; do
  ! virsh dominfo "$name" >/dev/null 2>&1 || die "VM $name already exists: run scripts/destroy.sh first"
done

# create_vm NAME VCPUS MEM_GIB DISK_GIB MGMT_MAC BUSINESS_MAC
# NIC order matters: the first becomes enp1s0 (management), the second enp2s0
# (business), matching templates/agent-config.yaml.
create_vm() {
  local name=$1 vcpus=$2 mem_gib=$3 disk_gib=$4 mgmt_mac=$5 business_mac=$6
  local disk="${VM_DISK_DIR}/${name}.qcow2"

  log "creating $name (${vcpus} vCPU, ${mem_gib} GiB, ${disk_gib} GiB, mgmt ${mgmt_mac}, business ${business_mac})"
  qemu-img create -q -f qcow2 -o preallocation=metadata "$disk" "${disk_gib}G"

  virt-install \
    --name "$name" \
    --memory "$((mem_gib * 1024))" \
    --vcpus "$vcpus" \
    --cpu host-passthrough \
    --machine q35 \
    --os-variant rhel9.0 \
    --import \
    --disk "path=${disk},format=qcow2,bus=virtio,cache=none,io=native,discard=unmap" \
    --disk "path=${AGENT_ISO},device=cdrom,bus=sata,readonly=on" \
    --boot hd,cdrom \
    --network "network=${MGMT_NET_NAME},mac=${mgmt_mac},model=virtio" \
    --network "network=${BUSINESS_NET_NAME},mac=${business_mac},model=virtio" \
    --graphics vnc,listen=127.0.0.1 \
    --rng /dev/urandom \
    --autostart \
    --noautoconsole
}

for i in 0 1 2; do
  mgmt_mac_var="MASTER_${i}_MGMT_MAC"
  business_mac_var="MASTER_${i}_BUSINESS_MAC"
  create_vm "${CLUSTER_NAME}-master-${i}" "$VM_VCPUS" "$VM_MEM_GIB" "$VM_DISK_GIB" \
    "${!mgmt_mac_var}" "${!business_mac_var}"
done
create_vm "${CLUSTER_NAME}-infra-0" "$INFRA_VCPUS" "$INFRA_MEM_GIB" "$INFRA_DISK_GIB" \
  "$INFRA_0_MGMT_MAC" "$INFRA_0_BUSINESS_MAC"

virsh list --all
log "VMs started: follow the install with scripts/90-wait.sh"
