# AWS EIP hairpinning and the talosctl endpoint/node split

A debugging story about a Talos cluster on AWS where `talosctl version` failed with `dial tcp ... i/o timeout`, even though every TCP/TLS-level probe to the same `IP:port` worked instantly. The error message blamed the network. The network was fine. The cause was AWS's refusal to let an EC2 instance reach itself through its own Elastic IP, combined with talosctl's "endpoint forwards to node" architecture happily setting up exactly that doomed path.

This document is meant to stand on its own as a write-up, so it covers (a) the symptom, (b) a reproducible diagnostic anyone can run in 60 seconds, (c) the talosctl client model, (d) the AWS networking behavior, and (e) the fix.

---

## TL;DR

`talosctl` makes a **two-hop call** when you've set both `endpoint` and `node`:

```
your laptop  ──TCP/50000──▶  endpoint  ──TCP/50000──▶  node
            (must be public)          (must be reachable from endpoint)
```

The `endpoint` is what your laptop dials. It must be a public address — the EC2 instance's Elastic IP.

The `node` is what the endpoint **proxies the RPC to**. On a single-master cluster, that proxy target is the *same machine*. If you set `node` to the same public EIP, the master tries to dial its own EIP from inside the VPC. AWS does not hairpin EIPs: the SYN goes out toward the Internet Gateway, the IGW doesn't know what to do with it, and the packet dies. By the time the failure bubbles back to your laptop, the error reads `dial tcp <EIP>:50000: i/o timeout` — pointing at the same EIP you successfully reached on the first hop, which is what makes the bug confusing.

**Fix:** set `node` to the instance's **private IP**. The endpoint forwards to itself via the local interface; the call returns instantly.

```sh
talosctl config endpoint  <PUBLIC_EIP>     # what laptop dials
talosctl config node      <PRIVATE_IP>     # what endpoint forwards to
```

---

## The symptom

After `terraform apply` succeeds and you've generated and applied machine configs, the very first `talosctl` call against the new cluster fails:

```text
$ talosctl version
Client:
    Tag:         v1.13.2
    SHA:         c5d7c653
    Go version:  go1.26.3
    OS/Arch:     darwin/arm64
Server:
error getting version: 1 error occurred:
    * 63.181.220.59: rpc error: code = Unavailable desc = connection error:
      desc = "transport: Error while dialing: dial tcp 63.181.220.59:50000: i/o timeout"
```

Read literally, the error says: "I tried to open a TCP connection to `63.181.220.59:50000` and it timed out." That is **false**. The TCP connection works fine, as the diagnostic below will show.

---

## Reproducible diagnostic

Run these in order. Each step probes a deeper layer of the connection. The point at which the output stops matching expectations tells you exactly which layer is broken.

```sh
EIP=63.181.220.59          # your master's public Elastic IP
PRIV=10.10.1.210           # your master's private IP (from `terraform output master_private_ip`)

# 1) Does the SG let your current public IP through?
curl -fsS https://api.ipify.org; echo
grep operator_cidr terraform/terraform.tfvars

# 2) Plain TCP to the Talos API
nc -vz -G 5 "$EIP" 50000
#  expected: "Connection to <EIP> port 50000 [tcp/*] succeeded!"

# 3) TLS handshake (no client cert — just confirms the server presents a real cert)
echo | openssl s_client -connect "$EIP":50000 -showcerts 2>/dev/null \
  | openssl x509 -text -noout | grep -A3 "Subject Alternative Name"
#  expected: includes both "IP Address:<EIP>" and "IP Address:<PRIV>"
#  if you see a self-signed Talos cert with no SANs, the node is still in maintenance mode

# 4) talosctl's own client config
echo "TALOSCONFIG=$TALOSCONFIG"          # must be set, not empty
talosctl config info                      # endpoints and nodes must be populated
env | grep -iE 'proxy|no_proxy' || echo "(no proxy vars — good)"

# 5) Now the failing call, with gRPC tracing
GRPC_GO_LOG_VERBOSITY_LEVEL=99 GRPC_GO_LOG_SEVERITY_LEVEL=info \
  talosctl version 2>&1 | tail -30
```

If steps 1–4 are clean (SG matches your IP, `nc` succeeds, the cert has the right SANs, talosconfig is loaded, no proxy vars), and step 5 still fails with `i/o timeout`, look closely at the verbose gRPC output. You should see something like:

```text
INFO: [core] [Channel #1 SubChannel #2] Subchannel picks a new address "63.181.220.59:50000" to connect
INFO: [core] [Channel #1 SubChannel #2] Subchannel Connectivity change to READY      ← TCP+mTLS handshake OK
INFO: [core] [Channel #1] Channel Connectivity change to READY
INFO: [core] [Channel #1] Channel Connectivity change to SHUTDOWN
INFO: [transport] [client-transport ...] Closing: rpc error: code = Canceled ...
error getting version: 1 error occurred:
    * 63.181.220.59: rpc error: code = Unavailable desc = connection error:
      desc = "transport: Error while dialing: dial tcp 63.181.220.59:50000: i/o timeout"
```

This is the giveaway: the channel reaches **READY** and then **SHUTDOWN**. The first hop (laptop → endpoint) completed an mTLS handshake. The `i/o timeout` that follows is **not from your laptop's TCP stack** — it's the failure of a *second* dial, executed by the endpoint, surfaced back through the same gRPC stream and rewrapped in the client's error message.

Confirm by routing the second hop through the private IP and re-running:

```sh
talosctl --nodes "$PRIV" version
#  expected: full Server: block, including NODE: <PRIV>, Tag: v1.x.y, etc.
```

If that works, you've reproduced the hairpin bug.

---

## The talosctl client model

`talosctl` doesn't have a 1:1 "connect to a node and talk to it" model. It has a fanout/proxy model that's the same shape whether you have one master or twenty workers.

A call carries two pieces of routing information:

- **`endpoints`** — one or more addresses the client opens a gRPC connection to. These are the only addresses your laptop ever sends packets to.
- **`nodes`** — zero or more "target" addresses passed as gRPC metadata. The endpoint reads this metadata, opens its own gRPC connections to each target, forwards the RPC, and streams responses back to the client.

```
                                  endpoint hop                proxy hop
            ┌────────────────┐    ┌──────────────┐           ┌──────────────┐
laptop  ───▶│ endpoint       │───▶│ talosd on    │──forward─▶│ talosd on    │
            │ (public EIP)   │    │ master       │           │ target node  │
            └────────────────┘    └──────────────┘           └──────────────┘
                                                              (could be self,
                                                               another CP,
                                                               or a worker)
```

If you set `nodes` empty, talosctl still defaults to using the endpoint as the node — so the proxy hop still happens, it just targets the endpoint itself. There's no "skip the proxy" mode for normal RPCs.

This design pays off the moment you have more than one node: you keep your laptop's allowlist scoped to the master's public IP (one SG rule, one cert SAN), and the master fans out to workers over the VPC's private network. The cost is that the `nodes` value must be an address the **endpoint** can reach — not necessarily one the **laptop** can reach.

On AWS, those are not the same set of addresses. Which is where it goes wrong.

---

## AWS EIPs are NAT, not addresses on the NIC

This is the load-bearing piece of AWS networking for understanding the bug.

An Elastic IP is **not** assigned to the instance's network interface. If you SSH into the master and run `ip addr`, you will see only the private IP (`10.10.1.210`). There is no `63.181.220.59` anywhere on the box. The EIP exists purely as a 1:1 NAT mapping inside AWS's Internet Gateway:

```
IGW NAT table:
  63.181.220.59  ⇄  10.10.1.210   (this instance)
```

That mapping is applied at the edge of the VPC, in both directions:

- **Inbound from internet to EIP**: the IGW rewrites the destination from EIP → private IP before the packet enters the VPC. The instance sees only its private IP on `dst`.
- **Outbound from instance to internet**: the IGW rewrites the source from private IP → EIP before the packet leaves the VPC. The internet sees only the EIP on `src`.

From inside the VPC, the EIP is *not a thing that points anywhere*. The VPC's route tables route public-IP destinations to the IGW; the IGW only knows how to do DNAT for traffic arriving from outside. Traffic originating inside the VPC and aimed at an EIP has nowhere to go: the IGW would have to "hairpin" — accept the packet, do the EIP→private DNAT, and send it back into the VPC. AWS's IGW does not do this. The packet is silently dropped.

This is documented AWS behavior, not a Talos quirk. It's also the same reason that, on a default VPC setup, an EC2 instance cannot reach *any* of its peers via their EIPs from inside the VPC — you have to use private IPs (or a NAT Gateway, or a load balancer, or a VPC endpoint, depending on what you're trying to do).

---

## The three packet paths

Concretely, for a master with private IP `10.10.1.210` and EIP `63.181.220.59`:

**Path A — Laptop → EIP (works)**

```
laptop ──▶ internet ──▶ IGW ──DNAT 63.181.220.59 → 10.10.1.210──▶ ENI ──▶ talosd
```

The IGW does its job, the instance receives a packet addressed to its own private IP, talosd accepts it. This is what makes `nc -vz <EIP> 50000` succeed and what makes the first gRPC hop reach `READY`.

**Path B — Instance → its own EIP (black hole)**

```
talosd on master ──▶ default route (VPC router) ──▶ "63.181.220.59 is public, go via IGW"
                ──▶ IGW ──▶ ??? (no hairpin, packet dropped)
```

No SYN-ACK ever returns. The dialer waits, hits its timeout, errors out. This is what happens when the endpoint tries to forward an RPC to a node whose address was set to the same EIP.

**Path C — Instance → its own private IP (works)**

```
talosd on master ──▶ kernel: "10.10.1.210 is one of my interfaces" ──▶ local delivery
```

The packet never leaves the box. Effectively a loopback. This is the path used when you set `node = 10.10.1.210`, and it's why the fix is so unceremonious.

---

## The fix

Set the `node` to the **private IP**. The `endpoint` stays as the public EIP.

```sh
export TALOSCONFIG=/path/to/talos/talosconfig

talosctl config endpoint <PUBLIC_EIP>
talosctl config node     <PRIVATE_IP>

talosctl config info     # verify they are different
talosctl version         # should now succeed
```

After this, every subsequent talosctl call works: `talosctl bootstrap`, `talosctl health`, `talosctl kubeconfig`, etc.

For a multi-node cluster, the pattern generalizes cleanly:

```sh
talosctl config endpoints <MASTER_PUBLIC_EIP>                                # one entry
talosctl config nodes     <MASTER_PRIVATE_IP> <WORKER1_PRIVATE_IP> ...      # all private
```

The master is the single ingress; it fans out to workers over the VPC's internal network. Workers don't need EIPs, SG rules for your operator IP, or cert SANs for any public address. The blast radius of "operator's home IP rotates" is one SG rule.

---

## Why the error message is so misleading

Worth spelling out, because this is the part that costs the most debugging time.

The text `transport: Error while dialing: dial tcp 63.181.220.59:50000: i/o timeout` is a Go `net.OpError` wrapped by gRPC's transport layer. It is generated wherever the failing `net.Dial` happens — but gRPC does **not** include any information about *which* dial it was. The client (your laptop) and the endpoint (the master) both run the same gRPC client code; both can produce this exact error string; and when the endpoint produces it, it's returned to the client over the established gRPC stream, where the client prefixes it with the node address it asked about (here: `63.181.220.59`).

So the error you see on your laptop is:

> "I asked node `63.181.220.59` for its version. The answer I got back was: dialing `63.181.220.59:50000` timed out."

Both halves of that sentence point at the public EIP, which makes it natural to assume the *first* hop is the one that broke. The first hop is fine. The address inside the error is the *second* hop's target, which happens to also be the EIP because you set `node = endpoint`.

The verbose gRPC log is what disambiguates: it shows the local gRPC channel reaching `READY` (first hop succeeded) before any error appears. If you ever see "i/o timeout but `nc` works", look for that READY/SHUTDOWN pattern — it's the fingerprint of a failed proxy hop disguised as a failed dial.

---

## Appendix: how this was originally diagnosed

The investigation path, for reference:

1. **Confirmed it wasn't an SG / IP-rotation problem.** Current public IP matched `operator_cidr`, and `nc -vz EIP 50000` succeeded with 59ms RTT — there was no firewall in the way.
2. **Confirmed it wasn't a TLS / SAN problem.** `openssl s_client -connect EIP:50000` completed a TLS handshake and returned a cert whose SAN list contained both the public EIP and the private IP.
3. **Confirmed it wasn't a proxy env var.** `env | grep -i proxy` was empty.
4. **Noticed the failure was implausibly fast.** `talosctl version` exited in ~400ms with "i/o timeout". A real TCP `i/o timeout` from `net.Dial` takes the OS default, typically tens of seconds. A sub-second `i/o timeout` is the signature of a wrapped error, not a real one.
5. **Turned on gRPC tracing** (`GRPC_GO_LOG_VERBOSITY_LEVEL=99 GRPC_GO_LOG_SEVERITY_LEVEL=info`) and saw the channel reach `READY` before the error. That moved the failure off the client and onto something the endpoint did after accepting the connection.
6. **Tested `talosctl --nodes <PRIVATE_IP> version`.** It worked. That confirmed the proxy hop was the failure point and the private IP was the right target.
7. **Cross-referenced AWS documentation** for the EIP-from-inside-VPC behavior; it's expected.

The lesson generalizes: when a high-level error message points at the layer you've already verified, distrust the message and instrument the layer above it.
