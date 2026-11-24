#!/usr/bin/env bash
# Create and boot the three VMs, each with one NIC (enp1s0) on the business network.
# Boot order is disk then CD-ROM: blank disks fall through to the agent ISO, and
# installed disks boot directly afterwards.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

[[ -f $AGENT_ISO ]] || die "$AGENT_ISO not found: run scripts/70-agent-iso.sh first"

for i in 0 1 2; do
  name="${CLUSTER_NAME}-master-${i}"
  ! virsh dominfo "$name" >/dev/null 2>&1 || die "VM $name already exists: run scripts/destroy.sh first"
done

for i in 0 1 2; do
  name="${CLUSTER_NAME}-master-${i}"
  mac_var="MASTER_${i}_MAC"
  disk="${VM_DISK_DIR}/${name}.qcow2"

  log "creating $name (${VM_VCPUS} vCPU, ${VM_MEM_GIB} GiB, ${VM_DISK_GIB} GiB, MAC ${!mac_var})"
  qemu-img create -q -f qcow2 -o preallocation=metadata "$disk" "${VM_DISK_GIB}G"

  virt-install \
    --name "$name" \
    --memory "$((VM_MEM_GIB * 1024))" \
    --vcpus "$VM_VCPUS" \
    --cpu host-passthrough \
    --machine q35 \
    --os-variant rhel9.0 \
    --import \
    --disk "path=${disk},format=qcow2,bus=virtio,cache=none,io=native,discard=unmap" \
    --disk "path=${AGENT_ISO},device=cdrom,bus=sata,readonly=on" \
    --boot hd,cdrom \
    --network "network=${BUSINESS_NET_NAME},mac=${!mac_var},model=virtio" \
    --graphics vnc,listen=127.0.0.1 \
    --rng /dev/urandom \
    --autostart \
    --noautoconsole
done

virsh list --all
log "VMs started: follow the install with scripts/90-wait.sh"
