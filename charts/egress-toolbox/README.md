# egress-toolbox

A UBI 9 pod with `curl`, `wget` and `ping` for testing traffic on the business network.

- **EgressIP:** the pod's outbound traffic leaves from `192.168.127.150` on the infra
  node, whichever node the pod runs on. Other pods in the namespace, including build
  pods, also use the business network but leave from their own node's address.
- **AdminNetworkPolicy:** like every application pod, the toolbox cannot reach any node
  address (business or management) except the API on the masters. Use it to verify
  that guardrail.
- **NetworkPolicy:** a default-deny policy blocks all traffic in and out of every pod in
  the namespace. The toolbox is then allowed out on TCP 443, 80 and 22 only. DNS, ICMP
  and all inbound traffic stay blocked. Build pods get a separate, narrow exception (TCP
  443 and 6443, the internal registry, cluster DNS) so the image can still be built.

## Prerequisites

- `scripts/95-post-install.sh` has run, so the infra node can host egress IPs.
- Cluster-admin rights, because `EgressIP` is a cluster-scoped resource.
- The internal image registry, for the in-cluster build. With `platform: none` it starts
  as `Removed`. On this lab, enable it with ephemeral storage. Images are lost when the
  registry pod restarts, so run `oc start-build` again after that:

  ```bash
  oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
    -p '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'
  ```

  To skip the registry, build `Containerfile` with podman, push it to any registry, and
  install with `--set build.enabled=false --set image.repository=<registry>/<repo>`.

## Install

```bash
helm install toolbox charts/egress-toolbox -n egress-demo --create-namespace
oc -n egress-demo logs -f bc/toolbox-egress-toolbox    # wait for the build
oc get egressip -o wide                                # check the IP is on a node
```

## Test

```bash
oc -n egress-demo rsh deploy/toolbox-egress-toolbox
curl -v http://192.168.127.x/                 # allowed
curl -v telnet://192.168.127.x:22             # allowed (shows the SSH banner)
ping 192.168.127.x                            # dropped by the NetworkPolicy
```

On the destination, the source address is `192.168.127.150`, for example in
`tcpdump -ni <if> host 192.168.127.150`.

## Values

| Key | Default | Purpose |
| --- | --- | --- |
| `egressIP.ips` | `[192.168.127.150]` | Addresses from `BUSINESS_EGRESS_*_OCTET`, unique per release |
| `networkPolicy.defaultDeny` | `true` | Deny all ingress and egress for every pod in the namespace |
| `networkPolicy.ports` | TCP 443, 80, 22 | Allowed egress ports |
| `networkPolicy.cidrs` | `[]` (any) | Limit destinations, for example `["192.168.127.0/24"]` |
| `networkPolicy.allowDNS` | `false` | Allow cluster DNS, so hostnames resolve |
| `build.enabled` | `true` | Build the image in the cluster (BuildConfig and ImageStream) |
| `image.repository` / `image.tag` | `""` / `latest` | External image when `build.enabled=false` |

## Notes

- The business network has no gateway, so only `192.168.127.0/24` is reachable for now
  (see the main README).
- The pod itself runs on a master (the infra node is tainted). OVN carries its traffic
  to the infra node, which sends it out with the egress IP as source.
- The pod runs under the `restricted-v2` SCC: non-root, read-only root filesystem, no
  capabilities, and a writable `/tmp`.
- The default deny applies to the whole namespace, so install the chart in its own
  namespace. Anything else running there loses its network access too.
- Use IP addresses unless `allowDNS=true`. With DNS allowed, cluster DNS forwards to the
  host's resolver on the business network.
