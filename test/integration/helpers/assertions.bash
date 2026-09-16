#!/usr/bin/env bash
# shellcheck shell=bash
#
# Every assertion takes a plain english reason as its last argument for clarity.
#
# Exit codes differentiate between connection (0), block (1), and failed probe (2).

probe() {
    python3 "$LAB_PROBE" "$@"
}

_probe_result() {
    PROBE_STATUS=0
    PROBE_OUTPUT="$(probe "$@" 2>&1)" || PROBE_STATUS=$?
}

_probe_broke() {
    printf 'BROKEN PROBE: %s\n' "$1" >&2
    printf '  the probe could not run, test not valid.\n' >&2
    printf '  %s\n' "$PROBE_OUTPUT" >&2
    return 1
}

# --------------------------------------------------------------------------
# Reachability
# --------------------------------------------------------------------------

assert_reachable() {
    local kind="$1" host="$2" port="$3" reason="$4"
    _probe_result "$kind" "$host" "$port"

    case "$PROBE_STATUS" in
    0) return 0 ;;
    2) _probe_broke "$reason" ;;
    *)
        printf 'UNREACHABLE: %s\n' "$reason" >&2
        printf '  expected %s %s:%s to work, it did not\n' "$kind" "$host" "$port" >&2
        printf '  %s\n' "$PROBE_OUTPUT" >&2
        return 1
        ;;
    esac
}

assert_blocked() {
    local kind="$1" host="$2" port="$3" reason="$4"
    _probe_result "$kind" "$host" "$port"

    case "$PROBE_STATUS" in
    1) return 0 ;;
    2) _probe_broke "$reason" ;;
    *)
        printf 'LEAK: %s\n' "$reason" >&2
        printf '  %s %s:%s got through the kill-switch\n' "$kind" "$host" "$port" >&2
        return 1
        ;;
    esac
}

# --------------------------------------------------------------------------
# Tunnel endpoint
# --------------------------------------------------------------------------
#
# If WG, real handshake, else, UDP round trip
assert_endpoint_reachable() {
    local reason="$1"

    if [[ "$LAB_HAVE_WIREGUARD" -eq 1 ]]; then
        lab_reset_tunnel_session
        assert_reachable tcp "$LAB_TUN_TARGET" "$LAB_PORT" "$reason (via a fresh WireGuard handshake)"
        [[ "$(lab_handshake_count)" != "0" ]] || {
            printf 'UNREACHABLE: %s\n' "$reason" >&2
            printf '  traffic flowed but WireGuard reports no completed handshake\n' >&2
            return 1
        }
    else
        assert_reachable udp "$LAB_EP_IP" "$LAB_EP_PORT" "$reason"
    fi
}

# --------------------------------------------------------------------------
# Multicast
# --------------------------------------------------------------------------

## Send an mDNS-shaped datagram over the LAN link and return 0 if ns received it, or 1
mcast_probe_arrives() {
    local marker="$BATS_TEST_TMPDIR/mcast.marker"
    rm -f "$marker"

    lab_ns python3 "$LAB_PROBE" mcast-listen "$LAB_MCAST_GROUP" "$LAB_MCAST_PORT" \
        --marker "$marker" --timeout 3 --iface-ip 203.0.113.2 \
        >"$BATS_TEST_TMPDIR/mcast.log" 2>&1 &
    local listener=$!
    sleep 0.3

    probe mcast-send "$LAB_MCAST_GROUP" "$LAB_MCAST_PORT" --iface-ip 203.0.113.1 >/dev/null 2>&1 || true
    wait "$listener" 2>/dev/null || true

    [[ -f "$marker" ]]
}

assert_mcast_arrives() {
    mcast_probe_arrives || {
        printf 'UNREACHABLE: %s\n' "$1" >&2
        printf '  the multicast control failed, so the blocking check below would be vacuous\n' >&2
        return 1
    }
}

assert_mcast_blocked() {
    if mcast_probe_arrives; then
        printf 'LEAK: %s\n' "$1" >&2
        printf '  a multicast datagram reached the far side of the LAN link\n' >&2
        return 1
    fi
    return 0
}

# --------------------------------------------------------------------------
# Firewall state
# --------------------------------------------------------------------------

assert_outgoing_policy() {
    local want="$1" got
    got="$(firewall_outgoing_policy)"
    [[ "$got" == "$want" ]] || {
        printf 'POLICY: expected the default outgoing policy to be %s, found %s\n' "$want" "$got" >&2
        return 1
    }
}

assert_state_file_exists() {
    [[ -f "$WGVPN_STATE_FILE" ]] || {
        printf 'STATE: expected %s to exist\n' "$WGVPN_STATE_FILE" >&2
        return 1
    }
}

assert_state_file_gone() {
    [[ ! -f "$WGVPN_STATE_FILE" ]] || {
        printf 'STATE: %s should have been removed, it still holds:\n%s\n' \
            "$WGVPN_STATE_FILE" "$(cat "$WGVPN_STATE_FILE")" >&2
        return 1
    }
}

# --------------------------------------------------------------------------
# Diagnostics
# --------------------------------------------------------------------------

# Dumped only when a test fails, from teardown.
dump_diagnostics() {
    printf '\n----- ufw -----\n' >&2
    ufw status verbose >&2 2>&1 || true
    printf '\n----- host interfaces -----\n' >&2
    ip -brief addr >&2 2>&1 || true
    printf '\n----- %s interfaces -----\n' "$LAB_NS" >&2
    lab_ns ip -brief addr >&2 2>&1 || true
    printf '\n----- routes -----\n' >&2
    ip route >&2 2>&1 || true
    if [[ -f "${WGVPN_STATE_FILE:-}" ]]; then
        printf '\n----- wg-vpn state -----\n' >&2
        cat "$WGVPN_STATE_FILE" >&2
    fi
    if [[ -f "${WGVPN_MOCK_LOG:-}" ]]; then
        printf '\n----- commands wg-vpn issued -----\n' >&2
        cat "$WGVPN_MOCK_LOG" >&2
    fi
    if [[ "${LAB_HAVE_WIREGUARD:-0}" -eq 1 ]]; then
        printf '\n----- wireguard -----\n' >&2
        wg show >&2 2>&1 || true
    fi
}

## Judge a connection that was opened before the kill-switch went up.
#  Must be called from the test body itself: `wait` only works in the shell
#  that owns the job.
assert_held_flow_severed() {
    local pid="$1" reason="$2" status=0
    wait "$pid" || status=$?

    case "$status" in
    1) return 0 ;;
    0)
        printf 'LEAK: %s\n' "$reason" >&2
        printf '  a connection established before the kill-switch engaged still carries data.\n' >&2
        printf "  ufw's before.rules accepts RELATED,ESTABLISHED on output ahead of every\n" >&2
        printf '  user rule, so existing flows survive the policy change unless wg-vpn\n' >&2
        printf '  drops their conntrack entries when it arms.\n' >&2
        return 1
        ;;
    *)
        printf 'BROKEN PROBE: %s (held connection exited %s)\n' "$reason" "$status" >&2
        return 1
        ;;
    esac
}
