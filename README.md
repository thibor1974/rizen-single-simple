# OpenShift 3-node compact cluster on a single KVM host

An OpenShift cluster of three VMs on one RHEL/Alma/Rocky 9 machine. All three are
control plane nodes that also run workloads (a compact cluster). Every node has a
single NIC on one business network. The host provides DNS, DHCP, NAT and load
balancing. Installation uses the Agent-based Installer with `platform: none`, so no
bootstrap VM is needed. MetalLB provides `LoadBalancer` Services on the business network.

```
 LAN clients
     |  DNS :53   API :6443   console/apps :80/:443
     v
 +---------------- KVM host (LAN_IP) -----------------------------------+
 |  ocp-dnsmasq@lan       cluster names -> LAN_IP                       |
 |  haproxy  LAN_IP       -> nodes (6443, 80, 443)                      |
 |  haproxy  .127.1       -> nodes (6443, 22623, 80, 443)               |
 |  ocp-dnsmasq@business  DHCP + cluster names -> .127.1                |
 |                                                                      |
 |  Business: virbr-ocp-biz 192.168.127.1/24, NAT to the LAN            |
 |   master-0 .10       master-1 .11       master-2 .12                 |  enp1s0 / br-ex
 |   MetalLB .100-149                                                   |
 +----------------------------------------------------------------------+
```

The same names resolve differently per side (split DNS). LAN clients get `LAN_IP`.
Nodes and pods get the host's business address (`192.168.127.1`). Both lead to
HAProxy, which forwards to the three nodes.

## Nodes

| | master-0, -1, -2 |
| --- | --- |
| Agent installer role | `master` (install-config has `compute.replicas: 0`) |
| Runs | Control plane, API, default ingress, MetalLB speaker, your workloads |
| Scheduling | Schedulable automatically (no workers) |
| Default size | 8 vCPU, 24 GiB, 200 GiB |
| NIC | `enp1s0`, DHCP reservation from the host, bridged into `br-ex` |

## Network

One libvirt NAT network (`ocp-business`, `192.168.127.0/24` by default) carries
everything: node IPs, etcd, the pod overlay, the internal API, the machine config
server, image pulls, DNS, NTP and MetalLB services.

| Name (inside the cluster) | Resolves to | HAProxy sends it to |
| --- | --- | --- |
| `api-int.<cluster>` and `api.<cluster>` | `192.168.127.1` | nodes `:6443` |
| `*.apps.<cluster>` | `192.168.127.1` | nodes `:80`/`:443` |
| `<node>.<cluster>` | node IP | n/a |
| machine config server | `192.168.127.1:22623` | nodes `:22623` (never offered to the LAN) |

**MetalLB:** a Service of `type: LoadBalancer` gets an address from
`192.168.127.100-149` (`BUSINESS_METALLB_*` in `cluster.env`), announced in layer 2
on `br-ex` by any of the three nodes. If the announcing node fails, another takes over.

**The network is NAT behind the host.** The cluster reaches the LAN and the internet,
but nothing outside the host can reach the node or MetalLB addresses: libvirt's NAT
rejects inbound connections. LAN clients use the API and routes through HAProxy on
`LAN_IP`. Test MetalLB services from the host itself. For real business clients,
change `templates/libvirt-network-business.xml` to bridge a physical NIC or VLAN,
and serve gateway and DNS from that network.

## Requirements

- RHEL, AlmaLinux or Rocky 9 with SSD/NVMe storage (etcd is latency sensitive).
- RAM of at least `3 x VM_MEM_GIB + 4` GiB. Minimum per node: 4 vCPU, 16 GiB, 100 GiB.
- A pull secret from <https://console.redhat.com/openshift/install/pull-secret>.
- An SSH key on the host for node access.

## Install

Copy this folder to the host, then as root:

```bash
cp cluster.env.example cluster.env
vi cluster.env                 # set LAN_IF and LAN_IP at minimum

scripts/00-preflight.sh        # read-only checks
scripts/05-render.sh           # writes host configs to build/ for review
scripts/10-packages.sh
scripts/20-network.sh          # business network (libvirt NAT)
scripts/30-dns-dhcp.sh
scripts/40-loadbalancer.sh
scripts/50-firewall.sh
scripts/60-tools.sh
scripts/70-agent-iso.sh
scripts/80-create-vms.sh
scripts/90-wait.sh             # roughly 45-90 minutes
scripts/95-post-install.sh     # MetalLB
```

Keep the pull secret on the host: `WORK_DIR` ends up holding it and the cluster's admin
credentials, so it should stay out of synced folders.

### Moving from the earlier 3 + 1, two-network layout

That layout had an `infra-0` VM and a management network. Reinstall:

```bash
# Remove the old VMs (the new destroy.sh only knows master-0..2)
for vm in ocp-master-{0,1,2} ocp-infra-0; do
  virsh destroy "$vm"; virsh undefine "$vm" --nvram
  rm -f /var/lib/libvirt/images/ocp/$vm.qcow2
done
# Remove the management network and its firewalld zone and policy
virsh net-destroy ocp-mgmt; virsh net-undefine ocp-mgmt
firewall-cmd --permanent --delete-policy=ocp-mgmt-admin
firewall-cmd --permanent --delete-zone=ocp-mgmt
firewall-cmd --reload

scripts/05-render.sh && scripts/30-dns-dhcp.sh && scripts/40-loadbalancer.sh && scripts/50-firewall.sh
scripts/70-agent-iso.sh --force && scripts/80-create-vms.sh && scripts/90-wait.sh && scripts/95-post-install.sh
```

The business network keeps its name and subnet, so it does not need redefining. The
node MACs are unchanged, so the DHCP reservations stay valid.

## Reaching the cluster from the LAN

LAN clients connect to `LAN_IP`, where HAProxy forwards the API (`6443`) and the
default ingress (`80`/`443`) to the nodes. They need DNS for the cluster names:

- **Router:** add a conditional forward of `ocp.lab.internal` to `LAN_IP`, if supported.
- **macOS, per machine:**
  ```bash
  sudo mkdir -p /etc/resolver
  echo "nameserver LAN_IP" | sudo tee /etc/resolver/ocp.lab.internal
  ```
  Check it with the macOS resolver (`dig` and `nslookup` skip `/etc/resolver`):
  ```bash
  dscacheutil -q host -a name console-openshift-console.apps.ocp.lab.internal
  curl -kI https://console-openshift-console.apps.ocp.lab.internal   # expect an HTTP status
  ```
- **`/etc/hosts` fallback:** it has no wildcards, so list every name you use. The console
  login also redirects through the OAuth server:
  ```
  LAN_IP  api.ocp.lab.internal
  LAN_IP  console-openshift-console.apps.ocp.lab.internal
  LAN_IP  oauth-openshift.apps.ocp.lab.internal
  ```

Then open `https://console-openshift-console.apps.ocp.lab.internal` and log in as
`kubeadmin` with the password from `WORK_DIR/auth/kubeadmin-password`.

The host itself is a client too: `30-dns-dhcp.sh` points `api` and the console names at
`LAN_IP` in `/etc/hosts`, so `oc` on the host works. SSH to the nodes from the host:
`ssh core@192.168.127.10`.

## Operating notes

- **Leave the cluster running for its first 24 hours** so the initial certificate rotation
  completes. Shutting down during that window can leave it unable to recover on its own.
- **Boot the nodes the day the ISO is generated.** Its certificates expire after 24 hours.
- **The host is a single point of failure.** Three masters provide etcd quorum and let you
  practise rolling upgrades, but do not protect against losing the machine. It is also
  the gateway, DNS and load balancer.
- VMs, the network, dnsmasq and HAProxy all start automatically when the host boots.

## Troubleshooting

| Check | Command |
| --- | --- |
| DHCP leases and requests | `journalctl -u ocp-dnsmasq@business -f` |
| Load balancer backends (`lan-*` and `cluster-*`) | `curl -s 'http://127.0.0.1:9000/;csv' \| cut -d, -f1,2,18` |
| SELinux denials | `ausearch -m avc -ts recent` |
| VM console (over SSH tunnel) | `virsh vncdisplay ocp-master-0` |
| Node logs | `ssh core@192.168.127.10 journalctl -b -f` |
| Node NIC and default route (expect `br-ex`) | `ssh core@192.168.127.10 'ip -br addr; ip route show default'` |
| Node IPs | `oc get nodes -o wide` |
| Default ingress pods | `oc -n openshift-ingress get pods -o wide` |
| MetalLB pool and speakers (one per node) | `oc -n metallb-system get ipaddresspool,l2advertisement,pods -o wide` |
| Installer progress detail | `openshift-install agent wait-for install-complete --dir "$WORK_DIR" --log-level=debug` |

## Start over

`scripts/destroy.sh` deletes the VMs, disks and ISO after a typed confirmation. Host
services and the network stay in place. Reinstall from `scripts/70-agent-iso.sh --force`.
