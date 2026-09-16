#!/usr/bin/env bats
#
# Does the kill-switch actually keep traffic in?
#
# The real `wg-vpn` binary runs against a real ufw, on a real kernel, with a
# real routing table. The only things faked are nmcli and sudo (see
# helpers/wgvpn.bash); everything the tool is actually being judged on is
# genuine. The peers it talks to live in an isolated network namespace built
# by helpers/lab.bash, which draws the topology.
#
# Two rules the suite holds itself to:
#
#   1. Every "this must be blocked" assertion is preceded by the same probe
#      passing with the kill-switch down. A blocking test with no control
#      proves only that something, somewhere, did not work.
#
#   2. A probe that cannot run (exit 2) never counts as a block (exit 1). A
#      listener that failed to bind must fail the suite, not quietly hand it
#      a free pass.
#
# DESTRUCTIVE: resets this machine's ufw configuration. It takes a snapshot
# first and puts it back afterwards, but that is best effort — run it through
# `make test-integration`, which sandboxes it in a disposable container.

bats_require_minimum_version 1.7.0

load helpers/lab
load helpers/firewall
load helpers/assertions
load helpers/wgvpn

setup_file() {
    lab_require_root
    lab_require_tools
    lab_require_consent
    firewall_snapshot
    lab_setup
}

teardown_file() {
    lab_teardown
    firewall_restore
}

setup() {
    lab_load
    wgvpn_workspace
    firewall_baseline
}

teardown() {
    # BATS_TEST_COMPLETED is set only when the body ran to the end, so this
    # is the failure path and nothing else.
    [[ -n "${BATS_TEST_COMPLETED:-}" ]] || dump_diagnostics

    # Put the lab back together even when a test died halfway through it.
    lab_ensure_tunnel_up
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "up installs kill-switch: only endpoint, tunnel, and allowed subnet get out" {
    ## Given Preconditions:
    # Assert baseline connectivity
    assert_endpoint_reachable "control: the VPN endpoint"
    assert_reachable tcp "$LAB_TUN_TARGET" "$LAB_PORT" "control: the far side of the tunnel"
    assert_reachable tcp 203.0.113.2 "$LAB_PORT" "control: the allowed LAN subnet"
    assert_reachable tcp 2001:db8:3::2 "$LAB_PORT" "control: the LAN subnet over IPv6"
    assert_reachable tcp 198.51.100.3 "$LAB_PORT" "control: a bystander on the uplink"
    assert_reachable tcp 2001:db8:1::3 "$LAB_PORT" "control: uplink bystander over IPv6"
    assert_reachable udp 198.51.100.3 "$LAB_DNS_PORT" "control: plaintext DNS on the uplink"
    assert_reachable udp "$LAB_EP_IP" "$LAB_EP_CLOSED_PORT" "control: another port on the endpoint host"
    assert_mcast_arrives "control: multicast over the LAN link"

    ## When:
    wgvpn up

    ## Then:
    assert_outgoing_policy deny

    # -- what kill-switch should allow --
    assert_endpoint_reachable "the endpoint named in the WireGuard config"
    assert_reachable tcp "$LAB_TUN_TARGET" "$LAB_PORT" "traffic leaving on the tunnel interface"
    assert_reachable tcp 203.0.113.2 "$LAB_PORT" "the subnet listed in subnets.list"

    # -- what kill-switch should block --
    assert_blocked tcp 198.51.100.3 "$LAB_PORT" \
        "a bystander on the same wire as the endpoint, reachable at L2 and listening"
    assert_blocked tcp 2001:db8:1::3 "$LAB_PORT" \
        "a bystander on the same wire as the endpoint over IPv6"
    assert_blocked udp 198.51.100.3 "$LAB_DNS_PORT" \
        "plaintext DNS escaping down the default route"
    assert_blocked udp "$LAB_EP_IP" "$LAB_EP_CLOSED_PORT" \
        "a second port on the endpoint host: endpoint rule must be port-scoped"
    assert_blocked tcp 2001:db8:3::2 "$LAB_PORT" \
        "IPv6 on the allowed subnet: an IPv4 CIDR in subnets.list must not open IPv6"
    assert_mcast_blocked \
        "mDNS announcing this machine to the local network"
}

@test "up: a connection opened beforehand does not outlive the kill-switch" {
    # ufw accepts RELATED,ESTABLISHED on output before user rules, so any established connection
    # will bypass the tunnel/kill-switch
    command -v conntrack >/dev/null 2>&1 ||
        skip "conntrack-tools is not installed, so established flows cannot be cleared"

    local ready="$BATS_TEST_TMPDIR/held.ready"
    local go="$BATS_TEST_TMPDIR/held.go"

    probe hold-tcp 198.51.100.3 "$LAB_PORT" --ready "$ready" --go "$go" --wait 60 &
    local held=$!
    lab_wait_for_file "$ready" "the connection held open across the kill-switch"

    wgvpn up
    assert_outgoing_policy deny
    touch "$go"

    assert_held_flow_severed "$held" "a TCP session opened before the kill-switch armed"
}

@test "up: the tunnel dying does not open the kill-switch" {
    # Arrange
    wgvpn up
    assert_outgoing_policy deny

    # Act: tunnel drops and wg-vpn doesn't know
    lab_tunnel_down

    # Assert
    assert_outgoing_policy deny
    assert_blocked tcp 198.51.100.3 "$LAB_PORT" "the uplink, once the tunnel is gone"
    assert_blocked tcp 2001:db8:1::3 "$LAB_PORT" "the uplink over IPv6, once the tunnel is gone"
    assert_blocked udp 198.51.100.3 "$LAB_DNS_PORT" "DNS looking for a way around the dead tunnel"
    assert_blocked tcp "$LAB_TUN_TARGET" "$LAB_PORT" "the tunnel's far side, which must not reroute"
    assert_state_file_exists
    # teardown brings the tunnel back up
}

@test "down: restores the network and clears its state" {
    # Arrange: tool has been started
    wgvpn up
    assert_state_file_exists

    # Act: turn off
    wgvpn down

    # Assert
    assert_outgoing_policy allow
    assert_state_file_gone
    assert_reachable tcp 198.51.100.3 "$LAB_PORT" "the uplink, once the kill-switch is off"
    assert_reachable udp 198.51.100.3 "$LAB_DNS_PORT" "DNS, once the kill-switch is off"
    assert_mcast_arrives "multicast, once the kill-switch is off"
}

@test "down: restores the network even if the WireGuard config goes missing" {
    # Arrange: tool has been started
    wgvpn up
    rm -f "$WGVPN_WG_CONFIG"

    # Act: turn off
    wgvpn down

    # Assert
    assert_outgoing_policy allow
    assert_state_file_gone
    assert_reachable tcp 198.51.100.3 "$LAB_PORT" "the uplink, after a teardown with no config file"
}

@test "down: restores the network even if the state file goes missing" {
    # Arrange: tool has been started
    wgvpn up
    rm -f "$WGVPN_STATE_FILE"

    # Act
    wgvpn_answer y down

    # Assert
    assert_outgoing_policy allow
    assert_reachable tcp 198.51.100.3 "$LAB_PORT" "the uplink, after a state-less recovery"
}

@test "up: refuses to arm kill-switch when ufw is inactive" {
    # Arrange
    ufw --force disable >/dev/null

    # Act
    run wgvpn_answer n up
    [ "$status" -ne 0 ]

    # Assert
    assert_outgoing_policy inactive
    assert_state_file_gone
}

@test "up: nmcli failure triggers rollback instead of leaving switch armed" {
    # Arrange
    export MOCK_NMCLI_UP_EXIT=1

    # Act
    run wgvpn up
    [ "$status" -ne 0 ]

    # Assert
    assert_outgoing_policy allow
    assert_state_file_gone
    assert_reachable tcp 198.51.100.3 "$LAB_PORT" "the uplink, after a rolled-back failure"
}
