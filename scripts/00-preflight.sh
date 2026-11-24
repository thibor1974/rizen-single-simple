#!/usr/bin/env bash
# Read-only checks. Reports every problem found, then fails if any were fatal.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root

errors=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  errors=$((errors + 1))
}
ok() { printf 'ok:   %s\n' "$*"; }

# shellcheck disable=SC1091
source /etc/os-release
if [[ ${PLATFORM_ID:-} == platform:el9 ]]; then
  ok "OS: ${PRETTY_NAME}"
else
  warn "written for RHEL/Alma/Rocky 9, found: ${PRETTY_NAME}"
fi

if grep -qE '\b(vmx|svm)\b' /proc/cpuinfo; then
  ok "CPU virtualization extensions present"
else
  fail "no vmx/svm CPU flag: enable virtualization in the BIOS"
fi

((VM_VCPUS >= 4)) || fail "VM_VCPUS=$VM_VCPUS is below the documented master minimum of 4"
((VM_MEM_GIB >= 16)) || fail "VM_MEM_GIB=$VM_MEM_GIB is below the documented master minimum of 16"
((VM_DISK_GIB >= 100)) || fail "VM_DISK_GIB=$VM_DISK_GIB is below the documented minimum of 100"
((INFRA_VCPUS >= 2)) || fail "INFRA_VCPUS=$INFRA_VCPUS is below the documented worker minimum of 2"
((INFRA_MEM_GIB >= 8)) || fail "INFRA_MEM_GIB=$INFRA_MEM_GIB is below the documented worker minimum of 8"
((INFRA_DISK_GIB >= 100)) || fail "INFRA_DISK_GIB=$INFRA_DISK_GIB is below the documented minimum of 100"

threads=$(nproc)
if ((VM_VCPUS > threads || INFRA_VCPUS > threads)); then
  fail "a VM's vCPU count exceeds the host's $threads threads"
else
  ok "vCPUs: 3 x $VM_VCPUS + 1 x $INFRA_VCPUS on $threads host threads"
fi

mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
mem_gib=$((mem_kib / 1024 / 1024))
needed=$((3 * VM_MEM_GIB + INFRA_MEM_GIB + 4))
if ((mem_gib < needed)); then
  fail "need ${needed} GiB RAM (3 x ${VM_MEM_GIB} + ${INFRA_MEM_GIB} + 4 for the host), host has ${mem_gib} GiB: lower VM_MEM_GIB (minimum 16) or INFRA_MEM_GIB (minimum 8)"
else
  ok "RAM: need ${needed} GiB, host has ${mem_gib} GiB"
fi

probe=$VM_DISK_DIR
while [[ ! -d $probe ]]; do probe=$(dirname "$probe"); done
free_gib=$(df --output=avail -BG "$probe" | tail -1 | tr -dc '0-9')
needed=$((3 * VM_DISK_GIB + INFRA_DISK_GIB + 2))
if ((free_gib < needed)); then
  warn "disks are thin provisioned but could grow to ${needed} GiB; ${free_gib} GiB free on $probe"
else
  ok "disk: ${free_gib} GiB free on $probe"
fi
if [[ $(lsblk -dno ROTA "$(findmnt -no SOURCE -T "$probe" | sed 's/\[.*//')" 2>/dev/null || echo 0) == 1 ]]; then
  warn "$probe appears to be on a rotational disk: etcd needs SSD/NVMe latency"
fi

if ip -4 -o addr show dev "$LAN_IF" 2>/dev/null | grep -qF " ${LAN_IP}/"; then
  ok "$LAN_IP is on $LAN_IF"
else
  fail "$LAN_IP is not configured on $LAN_IF"
fi

if command -v nmcli >/dev/null; then
  conn=$(nmcli -g GENERAL.CONNECTION device show "$LAN_IF" 2>/dev/null || true)
  if [[ -n $conn && $(nmcli -g ipv4.method connection show "$conn") == auto ]]; then
    warn "$LAN_IF uses DHCP: make sure $LAN_IP is reserved on your router"
  fi
fi

# A route to either subnet through anything but its own bridge is a clash.
check_subnet() {
  local label=$1 host_ip=$2 bridge=$3 cidr=$4 conflict
  if conflict=$(ip -4 -o route show to match "$host_ip" | grep -v '^default' | grep -v "dev ${bridge} "); then
    fail "$label subnet $cidr overlaps an existing route: $conflict"
  else
    ok "$label subnet $cidr is free"
  fi
}
check_subnet business "$BUSINESS_HOST_IP" "$BUSINESS_BRIDGE" "$BUSINESS_CIDR"
check_subnet management "$MGMT_HOST_IP" "$MGMT_BRIDGE" "$MGMT_CIDR"

check_port() {
  local proto=$1 port=$2 owner=$3 listeners
  listeners=$(ss -H "-ln${proto}p" "sport = :$port" 2>/dev/null || true)
  if [[ -n $listeners ]] && grep -qv "\"$owner\"" <<<"$listeners"; then
    fail "port $port/$proto is held by something other than $owner: $listeners"
  fi
}
for port in 80 443 6443 22623; do check_port t "$port" haproxy; done
check_port t 53 dnsmasq
check_port u 53 dnsmasq
if ((errors == 0)); then ok "service ports are free or already ours"; fi

if python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["auths"]' "$PULL_SECRET_FILE" 2>/dev/null; then
  ok "pull secret parses"
else
  fail "$PULL_SECRET_FILE is missing or is not a valid pull secret"
fi

if [[ -r $SSH_PUB_KEY_FILE ]]; then
  ok "SSH public key found"
else
  fail "$SSH_PUB_KEY_FILE not found: create one with ssh-keygen -t ed25519"
fi

((errors == 0)) || die "$errors preflight check(s) failed"
log "preflight passed"
