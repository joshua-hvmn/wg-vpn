# Security model

## Guarantees (when the kill-switch is armed)

1. **Default deny outgoing**  
   UFW’s default outgoing policy is set to `deny`. Only explicit `allow out` rules permit traffic.

2. **Endpoint is port-scoped**  
   Only UDP traffic to the exact `Endpoint` IP/hostname and port from the WireGuard config is allowed outside the tunnel. Other ports on the same host are blocked.

3. **Tunnel interface is allowed**  
   After the connection is up, `allow out on <wg-iface>` is installed. All traffic that leaves via the WireGuard device is permitted.

4. **Allowed subnets are explicit**  
   Only the CIDRs listed in `~/.config/wg-vpn/subnets.list` (IPv4 or IPv6) receive an `allow out to` rule. An IPv4 CIDR does **not** open the corresponding IPv6 range and vice versa.

5. **Established flows are flushed**  
   Before the policy becomes restrictive, `wg-vpn` deletes conntrack entries whose destination would be rejected by the new rules. This closes the window created by UFW’s stock `RELATED,ESTABLISHED` accept rule on the OUTPUT chain.

6. **Rollback on failure**  
   Any interruption during `up` (including a failed `nmcli connection up`) restores the previous UFW policy, removes the rules that were added, and deletes the managed connection profile.

7. **UFW must be active and IPv6-aware**  
   The tool refuses to arm the kill-switch if UFW is inactive or if `IPV6=yes` is not set in `/etc/default/ufw`.

## Deliberate trade-offs

### Inbound control channels

Local addresses that appear on the host’s interfaces are preserved when flushing conntrack. This keeps an existing SSH (or similar) session alive across the policy change. The consequence is that a long-lived _outbound_ connection whose remote address collides with a local address could also survive. In practice this is rare; the alternative (blind `conntrack -F`) would drop the session that is often used to administer the machine.

### Pre-existing NetworkManager profiles

If a connection with the same name already exists and was **not** created by `wg-vpn` (i.e. its description is not `wg-vpn-managed`), the tool will not delete it on teardown. Only the UFW rules are removed. This prevents accidental destruction of user-managed profiles.

### Hostname endpoints

When the WireGuard config contains a hostname, the initial `ufw allow out to <hostname> \ldots` is issued before the default deny. UFW resolves the name at rule-install time. Subsequent resolution changes are not tracked; prefer numeric endpoints for the highest assurance.

## What the kill-switch does **not** protect against

- Compromised root / kernel
- Traffic that never leaves the host (local sockets)
- Applications that bind to a raw socket and bypass the netfilter OUTPUT chain
- DNS leaks that occur _before_ the kill-switch is armed (use a system-wide DNS policy or a dedicated DNS kill-switch if this is a concern)
- IPv6 if the administrator later disables `IPV6=yes` after the tool has already run

## Reporting vulnerabilities

Please open a private security advisory on the GitHub repository or contact the maintainers. Do not file public issues for vulnerabilities that could lead to traffic leaks.
