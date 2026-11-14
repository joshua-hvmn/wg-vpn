# Changelog

## v0.2.0

### Added

- `wg-vpn config`: set the WireGuard config (`config wg`) and the subnets that bypass the
  kill-switch (`config subnets`), from a menu or with arguments; `config init` re-runs setup.
- `wg-vpn version`.
- Non-interactive mode (`NONINTERACTIVE=1`, or `CI` set): prompts take their safe default or
  stop, and never hang.
- A kill-switch integration suite (`make test-integration`): the real script against a real
  `ufw` in a container, probing for leaks over IPv4, IPv6, DNS and multicast.
- `SECURITY.md` (what the kill-switch guarantees, and what it doesn't) and `CONTRIBUTING.md`.

### Changed

- IPv6 is filtered by UFW instead of being switched off with `sysctl`. `up` requires
  `IPV6=yes` in `/etc/default/ufw`, and the default allowed subnets include `fc00::/7`.
- `up` refuses to arm the kill-switch while UFW is inactive.
- Connections opened before the kill-switch armed are cut (with `conntrack-tools`) instead of
  living on.
- The WireGuard interface is the only DNS route while the VPN is up (`dns-priority -1`,
  `dns-search ~.`).
- Teardown removes only a connection profile wg-vpn imported; one you made yourself is left
  alone.
- `make install` follows the standard `prefix`/`DESTDIR` variables, for packaging.
- Release tarballs are built with `git archive` (`make dist`) and include the tests. A release
  is linted and tested, kill-switch suite included, before it is signed, and a stable tag must
  be on `main` with a matching `VERSION`.

### Fixed

- `down` with no state file restores the firewall even when the config can't be read.
- A hostname `Endpoint` is refused with an explanation, before anything is changed.
- UFW's output is read correctly in a non-English locale.
- The installed `wg-vpn version` printed `unknown`; `wg-vpn config` with no arguments failed.
- `make install prefix=...` after a plain `make` installed a script that couldn't find its
  libraries.
