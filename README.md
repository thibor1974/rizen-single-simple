# OpenShift 3 + 1 on a single KVM host

An OpenShift cluster of four VMs on one RHEL/Alma/Rocky 9 machine: three control plane
nodes that also run workloads, and one infra node dedicated to business ingress (MetalLB)
and egress (EgressIP). The host provides DNS, DHCP, NAT and load balancing. Installation
uses the Agent-based Installer with `platform: none`, so no bootstrap VM is needed.

Every node has two NICs, with strictly separated roles:

- **Business (`enp2s0`)** is the machine network. Node IPs, the default route and DNS
  are here, so it carries all cluster traffic (etcd, pod overlay, kubelet, internal API,
  machine config server) and everything the cluster sends out (image pulls, NTP, DNS,
  EgressIP), plus MetalLB services.
- **Management (`enp1s0`)** is dedicated to admin access: node SSH, the API and the
  default ingress (web console, OAuth). The nodes only answer on it, and admins can
  reach it either through HAProxy on the host or routed, directly.

```
 LAN admins
     |  DNS :53   API :6443   console/apps :80/:443
     v
 +---------------- KVM host (LAN_IP) ---------------------------------------+
 |  ocp-dnsmasq@lan       cluster names -> LAN_IP (management path)          |
 |  haproxy  LAN_IP       -> masters' management IPs   (6443, 80, 443)       |
 |  haproxy  .127.1       -> masters' business IPs     (6443, 22623, 80, 443)|
 |  ocp-dnsmasq@business  DHCP + cluster names -> .127.1 (cluster path)      |
 |                                                                           |
 |  Management: virbr-ocp-mgmt 192.168.126.1/24  routed from LAN, admin ports|
 |   master-0 .10       master-1 .11       master-2 .12       infra-0 .20    |  enp1s0
 |   SSH API console    SSH API console    SSH API console    SSH            |
 |                                                                           |
 |  Business: virbr-ocp-biz 192.168.127.1/24  machine network, NAT to LAN    |
 |   master-0 .10       master-1 .11       master-2 .12       infra-0 .20    |  enp2s0 / br-ex
 |   etcd, overlay, kubelet, internal API, pulls...           MetalLB .100-149
 |                                                            EgressIP .150-199
 +---------------------------------------------------------------------------+
```

`network-flows.excalidraw` draws every flow of this design (management, cluster,
outbound, business ingress and egress, and what is blocked). Open it at
<https://excalidraw.com> or with the Excalidraw VS Code extension.

The same names resolve differently per side (split DNS). LAN admins get `LAN_IP` and
reach the masters over management. Nodes and pods get the host's business address and
stay on business.

## Nodes

| | master-0, -1, -2 | infra-0 |
| --- | --- | --- |
| Agent installer role | `master` | `worker` |
| Runs | Control plane, API, default ingress, your workloads | MetalLB speaker, EgressIP traffic |
| Scheduling | `mastersSchedulable: true` | Tainted `node-role.kubernetes.io/infra=reserved` |
| Management offers | SSH, API `6443`, default ingress `80`/`443` | SSH |
| Default size | 8 vCPU, 24 GiB, 200 GiB | 4 vCPU, 8 GiB, 100 GiB |

- The default ingress controller is pinned to the masters at install time
  (`templates/cluster-ingress-default-ingresscontroller.yaml`), so HAProxy's ingress
  backends are the masters only.
- The agent installer only knows `master` and `worker`. `scripts/95-post-install.sh` turns
  the worker into the infra node: it adds the `infra` role label, taints it so nothing
  else schedules there, and makes it the only `egress-assignable` node. The `worker`
  MachineConfig pool holds just this node.

## Networks

| | Business (`enp2s0`, bridged into `br-ex`) | Management (`enp1s0`) |
| --- | --- | --- |
| Role | Machine network | Admin access only |
| Addressing | DHCP reservation from the host | Static, set in `agent-config.yaml` |
| Default route and DNS | Yes, main table (host `.1`: NAT to the LAN, dnsmasq) | No DNS. A default route only in table 126, for replies sent from the management address |
| Carries | etcd, overlay, kubelet, internal API, MCS, image pulls, NTP, DNS, MetalLB, EgressIP | SSH, API, default ingress and web console |
| libvirt network | NAT (`ocp-business`) | Routed, no NAT, no libvirt rules (`ocp-mgmt`, mode `open`) |
| Host firewalld | Zone `libvirt`: DNS, DHCP and the internal LB ports. Host SSH removed | Zone `ocp-mgmt`: nodes cannot open connections to the host. Policy `ocp-mgmt-admin`: LAN may open SSH, `6443`, `80`, `443` to the nodes, nothing the other way |

OpenShift puts `br-ex` and the node IP on the interface that holds the default route,
so business becomes the primary NIC, and `machineNetwork` in `install-config.yaml` is
the business subnet.

**Same last octet on both networks.** master-0 is `192.168.127.10` (business) and
`192.168.126.10` (management).

**Replies on management always leave through management (policy routing).** The node's
main default route is on business, so without help a reply to an admin on another
subnet would leave through `br-ex`. Each node therefore has, from `agent-config.yaml`:

```
$ ip rule
1000:   from 192.168.126.10 lookup 126
$ ip route show table 126
default via 192.168.126.1 dev enp1s0
192.168.126.0/24 dev enp1s0 scope link
```

Anything sent *from* the management address (replies to SSH, API and ingress clients)
uses table 126 and leaves through `enp1s0`, whatever the client's subnet. Traffic the
node starts itself picks its `br-ex` address and the main table, so it never uses
management. The main table has no default route on `enp1s0`, so OpenShift still picks
business as the primary NIC. With a real management network, replace `192.168.126.1`
by its gateway (`MGMT_HOST_IP` in `scripts/lib.sh`).

### Inside the cluster

`ocp-dnsmasq@business` answers the nodes (and pods, through CoreDNS):

| Name | Resolves to | HAProxy sends it to |
| --- | --- | --- |
| `api-int.<cluster>` and `api.<cluster>` | `192.168.127.1` | masters' business IPs `:6443` |
| `*.apps.<cluster>` | `192.168.127.1` | masters' business IPs `:80`/`:443` |
| `<node>.<cluster>` | node business IP | n/a |
| machine config server | `192.168.127.1:22623` | masters' business IPs `:22623` |

So kubelets, operators, OAuth and console checks, and ingress canary probes never touch
management.

### Business services

- **Inbound:** a Service of `type: LoadBalancer` gets an address from the MetalLB range
  (`192.168.127.100-149` by default), announced on `br-ex` by infra-0 only. Backend pods
  can run on any node.
- **Outbound:** every pod leaves through business. By default it leaves from its own
  node's address. Pods selected by an EgressIP object leave from infra-0 with that
  address instead. Pick addresses from the EgressIP range:

  ```yaml
  apiVersion: k8s.ovn.org/v1
  kind: EgressIP
  metadata:
    name: my-app
  spec:
    egressIPs:
      - 192.168.127.150
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: my-app
  ```

- **Test application:** `charts/egress-toolbox` is a Helm chart for a UBI pod with curl, wget
  and ping. Its traffic leaves through an EgressIP, and a NetworkPolicy allows only TCP 443, 80
  and 22 out. See its README.
- **infra-0 is a single point of failure for business ingress and egress.** With one
  egress-assignable node there is no EgressIP failover, and MetalLB has one speaker.
- **In this lab, business is NAT behind the host.** The cluster reaches the LAN and the
  internet, but nothing outside the host can reach the MetalLB addresses: libvirt's NAT
  rejects inbound connections. Test services from the host itself, which has an address
  on business. For real business clients, change `templates/libvirt-network-business.xml`
  to bridge a physical NIC or VLAN, and serve gateway and DNS from that network.

## Security controls

Four layers enforce the separation.

| Control | Where | Enforces |
| --- | --- | --- |
| `99-master-node-firewall`, `99-worker-node-firewall` (`templates/node-firewall.nft`) | Every node, nftables, loaded before the network comes up | **Business:** connections to the node itself are accepted only from the other nodes and the host's internal LB (`192.168.127.1`). Anyone else is refused SSH `22`, API `6443`, ingress/console `80`/`443`, MCS `22623` and every other host service. **Management:** only SSH, plus API and default ingress on the masters. etcd, kubelet and MCS are refused. Nothing is routed in or out of `enp1s0`. |
| Ingress Node Firewall `business-masters`, `business-infra` (`templates/ingress-node-firewall.yaml`, operator from the Red Hat catalog) | Every node's `enp2s0`, eBPF/XDP, managed by the cluster | Packets to SSH `22`, API `6443`, MCS `22623` and, on the masters, default ingress `80`/`443` are dropped as they arrive from business, unless they come from a node or the internal LB. Installed by `scripts/96-ingress-node-firewall.sh`. |
| AdminNetworkPolicy `deny-pods-to-node-addresses` (`templates/admin-network-policy.yaml`) | Every application pod, enforced by OVN | Pods may reach the API on the masters' business addresses (`6443`, the `kubernetes` Service). They are denied every other node address: business node IPs, the EgressIP addresses, the whole management subnet, and MCS on the internal LB. No namespace NetworkPolicy can override it. |
| Host firewalld | KVM host | LAN may reach the management addresses on SSH, `6443`, `80`, `443` only, and nodes cannot open connections out of management. LB port `22623` only on business. Host SSH not offered on business. |

**Why both nftables and the Ingress Node Firewall.** They block the same management
ports from business, at two levels:

- The **Ingress Node Firewall** is the cluster-managed control. It is an OpenShift
  operator with its rules in Kubernetes objects (`oc get ingressnodefirewall`), and
  it drops at XDP, before OVS and netfilter see the packet.
- **nftables** protects the nodes from first boot, before any operator exists. It also
  closes every other host service (kubelet, etcd...), and it can do what the Ingress
  Node Firewall cannot: tell a MetalLB service from the node itself by destination
  address.

That limit shapes the infra-0 rules. Ingress Node Firewall rules match source, protocol
and port only, never the destination address. Denying `80`/`443` on infra-0 would
therefore also block MetalLB services on those ports. infra-0 runs neither the API nor
the default ingress, so it denies SSH, `6443` and `22623` only.

The Ingress Node Firewall is stateless, which is safe here: it only matches destination
ports, and replies to the nodes' own connections arrive on ephemeral ports.
`96-ingress-node-firewall.sh` checks three things after applying the rules:

- The internal LB still reaches every master's API.
- Every node is still Ready. If either check fails, the script deletes the rules again.
- An outside business client is refused. The host plays that client from the temporary
  address `192.168.127.254`.

To see which layer dropped a packet, check the nftables counters: they stay at zero
when XDP dropped the packet first.

The upstream project still marks the operator alpha. If the daemon does not tolerate
infra-0's taint, the script warns, and infra-0 stays covered by nftables only.

**Why the AdminNetworkPolicy is needed.** A pod's connection to a node address is
delivered inside the node (through `ovn-k8s-mp0`), or arrives from another node's address.
To the node firewall it looks like cluster traffic. The policy stops it at the pod's own
port, before any routing. This is how lateral movement from an EgressIP pod to the nodes
is blocked.

**Platform namespaces are exempt.** Monitoring scrapes kubelets, the OpenShift API servers
reach etcd, and network diagnostics probe nodes. `95-post-install.sh` labels `openshift`,
`openshift-*`, `kube-system`, `kube-public`, `kube-node-lease` and `metallb-system` with
`node-access/platform=true`, and the policy skips those. Project admins cannot label
namespaces, so applications cannot exempt themselves. **Re-run `95-post-install.sh` after
installing an operator into a new platform namespace**, or label that namespace yourself.

**Verifying:**

```bash
# Node IPs on business, management addresses on enp1s0
oc get nodes -o wide
ssh core@192.168.126.10 'ip -br addr; ip route show default'   # default via 192.168.127.1 dev br-ex

# Firewall loaded, with drop counters
for ip in 192.168.126.{10,11,12,20}; do ssh core@$ip sudo nft list table inet node_filter; done

# Management offers nothing else: etcd on a master's management address must time out
curl -m5 -k https://192.168.126.10:2379/ ; echo "exit $?"   # expect exit 28 (timeout)

# Application pods: the API works, node addresses do not (charts/egress-toolbox)
oc -n egress-demo exec deploy/toolbox-egress-toolbox -- curl -m5 -sk https://192.168.127.10:6443/readyz  # needs 6443 in the chart's networkPolicy.ports
oc -n egress-demo exec deploy/toolbox-egress-toolbox -- curl -m5 telnet://192.168.127.20:22   # expect a timeout
oc -n egress-demo exec deploy/toolbox-egress-toolbox -- curl -m5 telnet://192.168.126.10:22   # expect a timeout
```

To confirm that the AdminNetworkPolicy is what blocks the pod, run `oc delete
adminnetworkpolicy deny-pods-to-node-addresses` and repeat the test: the SSH test to
infra-0 now connects. Restore it with `oc apply -f build/admin-network-policy.yaml`.

To test the business-side firewall as an outside client would, attach a client VM to
`ocp-business` with a free address (e.g. `192.168.127.250/24`). `ssh`, `:6443`, `:443` and
`:10250` against `192.168.127.10-12,20` must all time out, while a MetalLB service IP must
answer.

## Requirements

- RHEL, AlmaLinux or Rocky 9 with SSD/NVMe storage (etcd is latency sensitive).
- RAM of at least `3 x VM_MEM_GIB + INFRA_MEM_GIB + 4` GiB. Minimums are 4 vCPU, 16 GiB,
  100 GiB per master and 2 vCPU, 8 GiB, 100 GiB for the infra node.
- OpenShift 4.16 or later (AdminNetworkPolicy).
- A pull secret from <https://console.redhat.com/openshift/install/pull-secret>.
- An SSH key on the host for node access.

## Install

Copy this folder to the host, then as root:

```bash
cp cluster.env.example cluster.env
vi cluster.env                 # set LAN_IF and LAN_IP at minimum

scripts/00-preflight.sh        # read-only checks
scripts/05-render.sh           # writes configs and manifests to build/ for review
scripts/10-packages.sh
scripts/20-network.sh          # business (NAT) and management (routed) networks
scripts/30-dns-dhcp.sh
scripts/40-loadbalancer.sh
scripts/50-firewall.sh
scripts/60-tools.sh
scripts/70-agent-iso.sh        # also checks the node firewall rules with nft -c
scripts/80-create-vms.sh
scripts/90-wait.sh             # roughly 45-90 minutes
scripts/95-post-install.sh     # node roles, MetalLB, EgressIP, AdminNetworkPolicy
scripts/96-ingress-node-firewall.sh  # cluster-managed firewall on business (self-checking)
```

Keep the pull secret on the host: `WORK_DIR` ends up holding it and the cluster's admin
credentials, so it should stay out of synced folders.

Until `95-post-install.sh` runs, the masters are not schedulable and infra-0 is an
ordinary worker, so cluster components without a node selector (monitoring, for example)
land on it. The script opens the masters and then taints infra-0, which moves those pods.

### Moving from the earlier layout

Earlier versions used management as the machine network. Converting a running cluster
would mean changing every node IP, so reinstall:

```bash
scripts/destroy.sh
virsh net-destroy ocp; virsh net-undefine ocp                     # old management network
virsh net-destroy ocp-business; virsh net-undefine ocp-business   # redefined as NAT
# Update cluster.env from cluster.env.example: VM_* became MGMT_*, and *_MAC became *_MGMT_MAC.
scripts/05-render.sh && scripts/20-network.sh && scripts/30-dns-dhcp.sh \
  && scripts/40-loadbalancer.sh && scripts/50-firewall.sh
scripts/70-agent-iso.sh --force && scripts/80-create-vms.sh && scripts/90-wait.sh && scripts/95-post-install.sh
```

`30-dns-dhcp.sh` disables the old `ocp-dnsmasq@vm` instance.

## Reaching the cluster from the LAN

There are two ways in, both over management:

| | Load-balanced (default) | Routed, direct to a node |
| --- | --- | --- |
| Client connects to | `LAN_IP` (HAProxy) | A master's management IP, e.g. `192.168.126.10` |
| Client needs | DNS for the cluster names (below) | A route to `192.168.126.0/24` via `LAN_IP` |
| Offers | API, default ingress | SSH (all nodes), API and default ingress (masters) |
| Survives a master going down | Yes | No, the client picks one node |

**Load-balanced** is what the cluster names point to, and what `oc` and the console use.
No route is needed: the client only has to reach `LAN_IP` (same LAN, or a VPN route to
the LAN).

**Routed** is for SSH, for checking one node, or for a load balancer elsewhere. Add the
route on your LAN router (best: every client gets it), or per client:

```bash
sudo route -n add -net 192.168.126.0/24 LAN_IP              # macOS
sudo ip route add 192.168.126.0/24 via LAN_IP               # Linux

curl -k https://192.168.126.10:6443/readyz                  # expect "ok"
curl -kI https://192.168.126.10/ -H 'Host: console-openshift-console.apps.ocp.lab.internal'
ssh core@192.168.126.10                                     # needs the cluster's SSH key
```

Replies come back through `enp1s0` thanks to the nodes' policy routing (see
[Networks](#networks)). The host forwards only SSH, `6443`, `80` and `443` from the LAN
into management. The node firewall narrows that further: infra-0 answers SSH only.
The API's certificate does not name the management IPs, so `oc` should keep using
`api.<cluster>`. To make it go direct, point that name at a master's management IP in
the client's `/etc/hosts`.

LAN clients need to ask the host about the cluster domain. Use one of:

- **Router:** add a conditional forward of `ocp.lab.internal` to `LAN_IP`, if supported.
- **macOS, per machine:**
  ```bash
  sudo mkdir -p /etc/resolver
  echo "nameserver LAN_IP" | sudo tee /etc/resolver/ocp.lab.internal
  ```
  Check it with the macOS resolver. `dig` and `nslookup` skip `/etc/resolver`, so they
  are not a valid test:
  ```bash
  scutil --dns | grep -A3 ocp.lab.internal           # the resolver is registered
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

The host itself is an admin client too: `30-dns-dhcp.sh` points `api` and the console
names at `LAN_IP` in `/etc/hosts`, so `oc` on the host uses the management path.

## Operating notes

- **Leave the cluster running for its first 24 hours** so the initial certificate rotation
  completes. Shutting down during that window can leave it unable to recover on its own.
- **Boot the nodes the day the ISO is generated.** Its certificates expire after 24 hours.
- **The host is a single point of failure.** Three masters provide etcd quorum and let you
  practise rolling upgrades, but do not protect against losing the machine. It is also
  the business gateway, DNS and internal load balancer.
- **The node firewall is custom.** Nothing in OpenShift manages it, so re-run the
  verification above after every upgrade.
- VMs, networks, dnsmasq and HAProxy all start automatically when the host boots.

## Troubleshooting

| Check | Command |
| --- | --- |
| DHCP leases and requests (business) | `journalctl -u ocp-dnsmasq@business -f` |
| Load balancer backends (`mgmt-*` and `cluster-*`) | `curl -s 'http://127.0.0.1:9000/;csv' \| cut -d, -f1,2,18` |
| SELinux denials | `ausearch -m avc -ts recent` |
| VM console (over SSH tunnel) | `virsh vncdisplay ocp-master-0` |
| Node logs | `ssh core@192.168.126.10 journalctl -b -f` |
| Node NICs and default route (expect `br-ex`) | `ssh core@192.168.126.20 'ip -br addr; ip route show default'` |
| Node IPs (expect business) | `oc get nodes -o wide` |
| Node roles and taints | `oc describe node infra-0 \| grep -A3 Taints` |
| Default ingress on the masters | `oc -n openshift-ingress get pods -o wide` |
| Management policy routing (expect `from <mgmt IP> lookup 126`) | `ssh core@192.168.126.10 'ip rule; ip route show table 126'` |
| Which way a reply to an admin leaves (expect `dev enp1s0`) | `ssh core@192.168.126.10 ip route get 192.168.1.50 from 192.168.126.10` |
| Host routing LAN -> management | `firewall-cmd --policy=ocp-mgmt-admin --list-all; firewall-cmd --get-zone-of-interface=virbr-ocp-mgmt` |
| Ingress Node Firewall rules and per-node sync state | `oc get ingressnodefirewall; oc get ingressnodefirewallnodestates -A` |
| Ingress Node Firewall daemon (expect one pod per node) | `oc -n openshift-ingress-node-firewall get pods -o wide` |
| Remove the Ingress Node Firewall rules (nftables stays) | `oc delete ingressnodefirewall business-masters business-infra` |
| Node firewall (counters show drops) | `ssh core@192.168.126.10 sudo nft list table inet node_filter` |
| Firewall service on a node | `ssh core@192.168.126.10 systemctl status node-firewall` |
| AdminNetworkPolicy and its CIDRs | `oc get adminnetworkpolicy deny-pods-to-node-addresses -o yaml` |
| Exempt platform namespaces | `oc get ns -l node-access/platform=true` |
| MetalLB pool and speakers (one, on infra-0) | `oc -n metallb-system get ipaddresspool,l2advertisement,pods -o wide` |
| Egress IP assignment | `oc get egressip -o wide` |
| Installer progress detail | `openshift-install agent wait-for install-complete --dir "$WORK_DIR" --log-level=debug` |

**Locked out of a node over SSH?** `oc debug node/<node>` reaches it through the API
instead, over business. From there, `chroot /host nft delete table inet node_filter`
removes the firewall until the next reboot. The `core` user has no password, so the VM
console is no fallback.

## Start over

`scripts/destroy.sh` deletes the VMs, disks and ISO after a typed confirmation. Host
services and networks stay in place. Reinstall from `scripts/70-agent-iso.sh --force`.
