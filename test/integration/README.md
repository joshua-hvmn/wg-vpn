# Kill-switch integration suite

A kill-switch is a security claim: _when the VPN is up, nothing leaves this
machine except through the tunnel._ Unit tests with a mocked `ufw` can check
that wg-vpn issues the right commands. They cannot check whether packets
actually stop, which is the only thing a user cares about.

This suite runs the real `wg-vpn` script against a real `ufw`, on a real
kernel, and then tries to leak — over IPv4, IPv6, DNS and multicast — from a
host that has somewhere to leak _to_.

```
make test-integration                       # sandboxed in a container
test/integration/run.sh --filter 'IPv6'     # one test, same sandbox
sudo modprobe wireguard                     # optional: enables the real-tunnel path
```

## The lab

Three links between the host under test and one isolated network namespace
holding every peer the host is allowed — or forbidden — to reach:

```
host / root netns                     netns: wgvpn-lab
----------------------------------    --------------------------------------
wgt-ext  198.51.100.1/24  ------->    wgt-ext-far  198.51.100.2  fake endpoint
         2001:db8:1::1/64                          198.51.100.3  bystander (v4)
                                                   2001:db8:1::3 bystander (v6)

wgt-lan  203.0.113.1/24   ------->    wgt-lan-far  203.0.113.2   allowed subnet
         2001:db8:3::1/64                          2001:db8:3::2 same subnet, v6

wgt-und  198.18.0.1/24    ------->    wgt-und-far  198.18.0.2    tunnel underlay
wgt-wg0  192.0.2.1/32     ==tunnel=>  wgt-wg1      192.0.2.2/32  tunnel target
```

Every address comes from a range reserved for documentation or benchmarking
(RFC 5737, RFC 3849, RFC 2544), so the lab cannot be confused with, or
collide with, a real network. Every interface is named `wgt-*` so cleanup can
be exhaustive without touching anything else.

Each blocked destination is reachable at layer 2 and has a listener running,
so "blocked" can only ever mean the firewall — never a missing route or an
absent server.

**With a real tunnel.** When `wireguard-tools` and the `wireguard` link type
are available, `wgt-und` carries a genuine WireGuard tunnel and the fake
`wg-vpn` config points at the _underlay_ endpoint — so the tool's own
endpoint rule is what has to permit the handshake, exactly as in production,
and `ufw allow out on <iface>` is evaluated against a real wireguard netdev
rather than a veth wearing its name. Before each enforced check the WireGuard
session is torn down and renegotiated, so traffic can only flow if the
kill-switch permits a brand-new handshake.

Without them, `wgt-und` plays the tunnel itself and the suite says so on
stderr. Reduced coverage on one point, never a silent downgrade.

## What is real and what is not

Real: `ufw` and its rules, the kernel's netfilter path, routing, the
WireGuard tunnel (when available), the `wg-vpn` entrypoint, its argument
routing, config parsing, locking, state file, and rollback.

Mocked: exactly two commands, and only because they would need hardware or a
network the test cannot own.

| Command | Why                                | What the mock does                                                               |
| ------- | ---------------------------------- | -------------------------------------------------------------------------------- |
| `nmcli` | No NetworkManager, no VPN provider | Reports the interface the lab built; can be told to fail `connection up`         |
| `sudo`  | The suite is already root          | Answers `sudo -v`, then `exec`s the real command so every `ufw` call really runs |

## Two rules the suite holds itself to

**Every block is preceded by a control.** Each "must be blocked" assertion is
run first with the kill-switch _down_, where it must succeed. A blocking
test with no control proves only that something, somewhere, did not work —
a listener that never bound, an address still tentative from duplicate
address detection, a typo in a probe. That failure mode is silent, and it
turns a leak into a green tick.

**A broken probe is never a pass.** `support/netlab.py` exits `0` when
traffic gets through, `1` when it is blocked, and `2` when the probe itself
could not run. Only `1` counts as blocked; `2` fails the test with
`BROKEN PROBE` and the reason.

## What each test proves

| Test                                                              | Claim                                                                                                                                                                       |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `only the endpoint, the tunnel and the allowed subnet get out`    | The core claim, over TCP, UDP, IPv4, IPv6, DNS and mDNS                                                                                                                     |
| `a connection opened beforehand does not outlive the kill-switch` | `ufw` accepts `RELATED,ESTABLISHED` on output ahead of every user rule, so flows that predate the switch keep using the old route until their conntrack entries are cleared |
| `the tunnel dying does not open the kill-switch`                  | The scenario the tool exists for: the tunnel disappears without telling anyone                                                                                              |
| `down: restores the network and clears its state`                 | Off means off, and leaves nothing behind                                                                                                                                    |
| `down: ... even if the WireGuard config has vanished`             | Teardown needs the state file, not the config; refusing to restore the network over a missing file strands the machine offline                                              |
| `down: recovers when the state file is missing`                   | The worst moment to fail: rules still loaded, no record of them, and this is the only way back online                                                                       |
| `a failed connection rolls back`                                  | A failed `up` must not leave the switch armed                                                                                                                               |
| `refuses to arm while ufw is inactive`                            | A kill-switch that believes it is on while the firewall is off is worse than none                                                                                           |

## What it does not prove

- **Traffic that never reaches netfilter.** `AF_PACKET` sockets — DHCP
  clients, some link-layer tooling — bypass `OUTPUT` entirely. `ufw` cannot
  stop them and neither can this suite.
- **The LAN bypass is a deliberate hole.** Anything in `subnets.list` is
  allowed to leave outside the tunnel, including DNS to a router on that
  subnet. The suite pins the list to a single documentation range so the
  _mechanism_ is tested without the default RFC1918 seed list quietly
  allowing half the assertions through. Whether you want that hole on your
  own machine is a configuration question, not a bug.
- **IPv6 on the allowed subnet.** An IPv4 CIDR in `subnets.list` does not
  open IPv6, and the suite asserts exactly that. If you want LAN IPv6, the
  ranges have to be listed.
- **Timing during `up`.** The window between importing the connection and
  the policy flipping to deny is not measured.

## Safety

The suite resets `ufw` on whatever machine it runs on. Three things stand
between that and someone's workstation:

1. `make test-integration` runs it in a container with `--network none`, so
   its firewall and its interfaces are its own.
2. Outside a container or CI, it refuses to start without
   `WGVPN_ALLOW_UFW_RESET=1`.
3. It snapshots `/etc/ufw` and `/etc/default/ufw` before touching anything
   and restores them afterwards — best effort, and not a substitute for 1.

## Files

```
killswitch.bats          the spec: what is claimed, in order
helpers/lab.bash         the namespace, links, tunnel and listeners
helpers/firewall.bash    ufw snapshot, restore, and the per-test baseline
helpers/assertions.bash  the vocabulary the spec is written in
helpers/wgvpn.bash       isolated config/state plus the two mocks
support/netlab.py        every probe and listener, one exit-code contract
run.sh                   the sandbox
Dockerfile               the sandbox's contents
```

The helpers are plain `.bash` so `shellcheck` can read them; keeping logic
out of the `.bats` file is what makes that possible.
