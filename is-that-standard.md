Partly. The goal is very common; the exact way we have assembled it is not a reference design.

## What is standard

- **Separating management and business traffic.** Most regulated or telco-style environments ask for this.
- **Each building block on its own.** MetalLB on a secondary interface, a sharded IngressController and egress IPs on a secondary NIC are all documented features. For instance, the egress IP docs cover using egress IPs on any physical interface with IP connectivity, not only `br-ex`.

## What is not standard

- **The default-deny nftables rule set on the host.** This is the custom part. Nothing in the product manages it, it must be kept in step with OVN-Kubernetes behaviour across upgrades, and I would confirm the support position with Red Hat before relying on it. Ingress Node Firewall is the supported host firewall, but it cannot express your "replies only" requirement.
- **MetalLB L2 on a secondary NIC with routed clients.** It works in simple topologies, but the reply-path problem is well known enough that the documented answer for asymmetric routing across several host interfaces combines MetalLB, NMState and OVN-Kubernetes in a VRF setup using BGP.
- **Switching the cluster to `routingViaHost`.** Supported, but a cluster-wide change made mainly to serve one interface.

So what you have is a valid, buildable design made of supported parts, with one custom piece holding it together. It needs testing after every OpenShift upgrade.

## How this is more commonly done

| Pattern | How the separation is achieved | Trade-off |
|---|---|---|
| **External load balancers and firewalls** (most common) | Nodes have one network. The API sits behind a management-side load balancer, app ingress behind a business-side one, and firewalls between zones enforce who reaches what | Separation lives in the network, not on the node; needs a network team and LB capacity |
| **Dedicated ingress/egress nodes** | Only a few infra nodes carry the business NIC and run the business router and egress IPs; masters and ordinary workers never touch that network | Much smaller surface to firewall; your nftables rules then apply to a handful of nodes |
| **MetalLB BGP with VRF** | The business NIC sits in its own VRF, so routing is separated by design | Needs BGP peering with the business network |
| **Pods attached directly to the business network** (Multus) | Apps get a second interface; nodes have no IP there | Apps must handle two interfaces; no Routes or Services on that side |

## My suggestion

Combine your design with the second pattern: put the business NIC only on a small pool of dedicated nodes, and run the sharded router and the egress IPs there. The API then needs no protection on the business side at all, because control-plane nodes are not connected to it, and the custom firewall covers three or four nodes instead of the whole cluster.

Before building it, open a Red Hat support case describing the nftables part and ask for their position in writing. Their answer will show how much risk the custom piece carries for you.