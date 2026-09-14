#!/usr/bin/env bats
#
# Real kill-switch integration test.
#
# Runs the actual `wg-vpn` binary as a subprocess – real argument routing,
# real locking, real config loading, real ufw enforcement.
# `nmcli` is the only thing faked (no real WireGuard peer available).
#
# Three veth pairs into an isolated netns, each proving exactly one rule
# type in isolation:
#   ep pair   (198.51.100.0/24, 2001:db8:1::/64) – the specific endpoint allow rule
#   tun pair  (192.0.2.0/24)                     – the allow-out-on-<iface> rule (see WIREGUARD TUNNEL DEVICE)
#   sub pair  (203.0.113.0/24, 2001:db8:1::/64)  – the allow-out-to-<subnet> rule
#
# subnets.list is set explicitly to 203.0.113.0/24 only, so this test
# never depends on (or collides with) the default RFC1918 seed list.
#
# After `up` the test asserts both the positive paths (allowed traffic)
# AND the negative paths (everything else must be blocked) across IPv4,
# IPv6, DNS (UDP/53), and mDNS/multicast (UDP/5353).  That is the
# actual leak check.
#
# ------------------------
# WIREGUARD TUNNEL DEVICE
# ------------------------
# When `wg` (wireguard-tools) and the `wireguard` kernel link type are
# available, the "tun" pair is used as the *underlay* for a genuine
# WireGuard tunnel: wg0 on the host, wg1 inside KS_NS. This makes the
# `sudo ufw allow out on <iface>` rule get evaluated against a real
# `wireguard`-type netdev instead of a plain veth pretending to be one.
#
# If wireguard-tools or the kernel module isn't available, this falls
# back to the previous plain-veth behaviour and logs a note — reduced
# coverage on that one point, not a hard failure of the whole suite.
#
# DESTRUCTIVE: resets/disables the real ufw firewall wherever it runs.
# Always invoke via `make test` – never bats directly on a real host.

KS_NS="wgtest_ks"
WGVPN_BIN="./wg-vpn"

setup_file() {
    [[ "$(id -u)" -eq 0 ]] || skip "requires root"
    command -v ufw >/dev/null || skip "ufw not installed"

    if [[ ! -f /.dockerenv && -z "${CI:-}" && -z "${WGVPN_CONFIRM_TEST_RESET_UFW:-}" ]]; then
        echo "REFUSING TO RUN: this resets/disables ufw with no restore." >&2
        echo "Run it via 'make test', not directly." >&2
        return 1
    fi

    ip netns add "$KS_NS"

    # Endpoint veth pair
    ip link add wgt-ep type veth peer name wgt-ep-far
    ip link set wgt-ep-far netns "$KS_NS"
    ip addr add 198.51.100.1/24 dev wgt-ep
    ip -6 addr add 2001:db8:1::1/64 dev wgt-ep
    ip link set wgt-ep up
    ip netns exec "$KS_NS" ip addr add 198.51.100.2/24 dev wgt-ep-far
    ip netns exec "$KS_NS" ip addr add 198.51.100.3/24 dev wgt-ep-far
    ip netns exec "$KS_NS" ip -6 addr add 2001:db8:1::2/64 dev wgt-ep-far
    ip netns exec "$KS_NS" ip -6 addr add 2001:db8:1::3/64 dev wgt-ep-far
    ip netns exec "$KS_NS" ip link set wgt-ep-far up

    # Tunnel-interface veth pair (name reported by the nmcli mock's GENERAL.DEVICES)
    ip link add wgt-tun type veth peer name wgt-tun-far
    ip link set wgt-tun-far netns "$KS_NS"

    WG_UNDERLAY_HOST=10.99.0.1
    WG_UNDERLAY_PEER=10.99.0.2
    WG_OVERLAY_HOST=192.0.2.1
    WG_OVERLAY_PEER=192.0.2.2
    WG_TUN_IFACE="wgt-tun"
    HAVE_REAL_WG=0

    if command -v wg >/dev/null 2>&1 && ip link add dev wg0 type wireguard 2>/dev/null; then
        HAVE_REAL_WG=1
        WG_TUN_IFACE="wg0"

        ip addr add "${WG_UNDERLAY_HOST}/24" dev wgt-tun
        ip link set wgt-tun up
        ip netns exec "$KS_NS" ip addr add "${WG_UNDERLAY_PEER}/24" dev wgt-tun-far
        ip netns exec "$KS_NS" ip link set wgt-tun-far up
        ip netns exec "$KS_NS" ip link add dev wg1 type wireguard

        HOST_PRIV=$(wg genkey)
        HOST_PUB=$(printf '%s' "$HOST_PRIV" | wg pubkey)
        PEER_PRIV=$(wg genkey)
        PEER_PUB=$(printf '%s' "$PEER_PRIV" | wg pubkey)

        ip addr add "${WG_OVERLAY_HOST}/32" dev wg0
        wg set wg0 private-key <(printf '%s' "$HOST_PRIV") listen-port 51821 \
            peer "$PEER_PUB" allowed-ips "${WG_OVERLAY_PEER}/32" endpoint "${WG_UNDERLAY_PEER}:51821"
        ip link set wg0 up
        ip route add "${WG_OVERLAY_PEER}/32" dev wg0

        ip netns exec "$KS_NS" ip addr add "${WG_OVERLAY_PEER}/32" dev wg1
        ip netns exec "$KS_NS" wg set wg1 private-key <(printf '%s' "$PEER_PRIV") listen-port 51821 \
            peer "$HOST_PUB" allowed-ips "${WG_OVERLAY_HOST}/32" endpoint "${WG_UNDERLAY_HOST}:51821"
        ip netns exec "$KS_NS" ip link set wg1 up
        ip netns exec "$KS_NS" ip route add "${WG_OVERLAY_HOST}/32" dev wg1
    else
        echo "NOTE: wireguard-tools or wg kernel link type unavailable; falling back to plain veth"
        ip addr add 192.0.2.1/24 dev wgt-tun
        ip link set wgt-tun up
        ip netns exec "$KS_NS" ip addr add 192.0.2.2/24 dev wgt-tun-far
        ip netns exec "$KS_NS" ip link set wgt-tun-far up
    fi

    echo "$WG_TUN_IFACE" >"$BATS_FILE_TMPDIR/wg_tun_iface"
    echo "$HAVE_REAL_WG" >"$BATS_FILE_TMPDIR/have_real_wg"

    # Allowed-subnet veth pair
    ip link add wgt-sub type veth peer name wgt-sub-far
    ip link set wgt-sub-far netns "$KS_NS"
    ip addr add 203.0.113.1/24 dev wgt-sub
    ip -6 addr add 2001:db8:3::1/64 dev wgt-sub
    ip link set wgt-sub up
    ip netns exec "$KS_NS" ip addr add 203.0.113.2/24 dev wgt-sub-far
    ip netns exec "$KS_NS" ip -6 addr add 2001:db8:3::2/64 dev wgt-sub-far
    ip netns exec "$KS_NS" ip link set wgt-sub-far up

    ip netns exec "$KS_NS" ip link set lo up

    # Background services inside the netns
    ip netns exec "$KS_NS" python3 "$(pwd)/test/integration/support/udp_echo.py" 198.51.100.2 51820 &
    echo $! >"$BATS_FILE_TMPDIR/pids"
    ip netns exec "$KS_NS" python3 -m http.server 8080 --bind 198.51.100.3 >/dev/null 2>&1 &
    echo $! >>"$BATS_FILE_TMPDIR/pids"
    ip netns exec "$KS_NS" python3 -m http.server 8080 --bind 192.0.2.2 >/dev/null 2>&1 &
    echo $! >>"$BATS_FILE_TMPDIR/pids"
    ip netns exec "$KS_NS" python3 -m http.server 8080 --bind 203.0.113.2 >/dev/null 2>&1 &
    echo $! >>"$BATS_FILE_TMPDIR/pids"
    # IPv6 leak target
    ip netns exec "$KS_NS" python3 -m http.server 8080 --bind 2001:db8:1::3 >/dev/null 2>&1 &
    echo $! >>"$BATS_FILE_TMPDIR/pids"
    # DNS leak target, port 53
    ip netns exec "$KS_NS" python3 "$(pwd)/test/integration/support/udp_echo.py" 198.51.100.3 53 &
    echo $! >"$BATS_FILE_TMPDIR/pids"
    sleep 0.3

    if [[ -f /etc/default/ufw ]]; then
        if grep -q '^IPV6=' /etc/default/ufw; then
            grep -q '^IPV6=yes' /etc/default/ufw || sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
        else
            echo 'IPV6=yes' >>/etc/default/ufw
        fi
    fi
    ufw --force reset >/dev/null 2>&1 || true
    ufw --force default allow outgoing >/dev/null 2>&1 || true
    ufw --force default deny incoming >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1
    ufw reload >/dev/null 2>&1 || true
}

teardown_file() {
    ufw --force disable >/dev/null 2>&1 || true
    ufw --force reset >/dev/null 2>&1 || true
    if [[ -f "$BATS_FILE_TMPDIR/pids" ]]; then
        while read -r pid; do kill "$pid" 2>/dev/null || true; done <"$BATS_FILE_TMPDIR/pids"
    fi
    ip netns del "$KS_NS" 2>/dev/null || true
    # Host-side veth names (the far sides disappear with the netns)
    ip link del wgt-ep 2>/dev/null || true
    ip link del wgt-tun 2>/dev/null || true
    ip link del wgt-sub 2>/dev/null || true
    ip link del wg0 2>/dev/null || true
}

setup() {
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
    export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
    mkdir -p "$XDG_CONFIG_HOME/wg-vpn" "$XDG_STATE_HOME/wg-vpn"

    cat >"$XDG_CONFIG_HOME/wg-vpn/wg-vpn.conf" <<EOF
WG_CONFIG_DIR="$BATS_TEST_TMPDIR"
WG_CONFIG_FILE="peer.conf"
EOF

    cat >"$BATS_TEST_TMPDIR/peer.conf" <<'EOF'
[Interface]
PrivateKey = dummyprivatekey=
Address = 192.0.2.2/32

[Peer]
PublicKey = dummypublickey=
Endpoint = 198.51.100.2:51820
EOF

    # Only the one subnet we want to allow – never the default RFC1918 list
    echo "203.0.113.0/24" >"$XDG_CONFIG_HOME/wg-vpn/subnets.list"

    # Interface name reported by nmcli's GENERAL.DEVICES
    WG_TUN_IFACE="$(cat "$BATS_FILE_TMPDIR/wg_tun_iface" 2>/dev/null || echo wgt-tun)"
    HAVE_REAL_WG="$(cat "$BATS_FILE_TMPDIR/have_real_wg" 2>/dev/null || echo 0)"
    export WG_TUN_IFACE HAVE_REAL_WG

    MOCK_BIN_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$MOCK_BIN_DIR"

    # nmcli is fully mocked – we never bring up a real connection, reports tunnel device from setup_file
    cat >"$MOCK_BIN_DIR/nmcli" <<EOF
#!/usr/bin/env bash
case "\$*" in
*"GENERAL.DEVICES"*)        echo "$WG_TUN_IFACE" ;;
*"connection.description"*) echo "wg-vpn-managed" ;;
*"connection import"*)      exit 0 ;;
*"connection modify"*)      exit 0 ;;
*"connection up"*)          exit "\${MOCK_NMCLI_UP_EXIT:-0}" ;;
*"connection delete"*)      exit 0 ;;
*"connection show"*)        exit 1 ;;   # "not yet imported"
*)                          exit 0 ;;
esac
EOF
    chmod +x "$MOCK_BIN_DIR/nmcli"

    # sudo mock must handle "sudo -v" (credential refresh) and otherwise
    # just execute the real command so ufw rules are actually installed.
    cat >"$MOCK_BIN_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
# "sudo -v" is only a credential check – succeed silently
if [[ "$1" == "-v" ]]; then
	exit 0
fi
# Everything else runs for real (ufw, etc.)
exec "$@"
EOF
    chmod +x "$MOCK_BIN_DIR/sudo"

    export PATH="$MOCK_BIN_DIR:$PATH"

    # Guarantee a clean, known-good policy before every test.
    # `ufw --force reset` alone is not always enough in this environment
    # (policy can remain deny, which then gets captured as PREV_UFW_POLICY
    # and "restored" on down/rollback, defeating the leak checks).
    ufw --force reset >/dev/null 2>&1 || true
    ufw --force default allow outgoing >/dev/null 2>&1 || true
    ufw --force default deny incoming >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
}

teardown() {
    ufw --force reset >/dev/null 2>&1 || true
    ufw --force default allow outgoing >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Helpers – keep the assertions readable
# ---------------------------------------------------------------------------

# Assert that a TCP connect succeeds (status 0)
assert_tcp_ok() {
    local host="$1" port="$2"
    run python3 test/integration/support/tcp_probe.py "$host" "$port"
    if [[ "$status" -ne 0 ]]; then
        echo "FAILED CONNECT: Expected TCP $host:$port to SUCCEED, but it failed" >&2
    fi
    [ "$status" -eq 0 ]
}

# Assert that a TCP connect is blocked (status != 0)
assert_tcp_blocked() {
    local host="$1" port="$2"
    run python3 test/integration/support/tcp_probe.py "$host" "$port"
    if [[ "$status" -eq 0 ]]; then
        echo "LEAK: Expected TCP $host:$port to be BLOCKED, but it succeeded!" >&2
    fi
    [ "$status" -ne 0 ]
}

# Assert that the UDP endpoint handshake works
assert_udp_ok() {
    local host="$1" port="$2"
    run python3 test/integration/support/udp_probe.py "$host" "$port"
    if [[ "$status" -ne 0 ]]; then
        echo "FAILED HANDSHAKE: Expected UDP $host:$port to SUCCEED, but it failed!" >&2
    fi
    [ "$status" -eq 0 ]
}

# Assert that a UDP round-trip is blocked.
assert_udp_blocked() {
    local host="$1" port="$2"
    run python3 test/integration/support/udp_probe.py "$host" "$port"
    if [[ "$status" -eq 0 ]]; then
        echo "LEAK: Expected UDP $host:$port to be BLOCKED, but a reply came back!" >&2
    fi
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "'up' installs kill-switch: allowed paths work, everything else is blocked" {
    run bash -c "$WGVPN_BIN up </dev/null"
    if [[ "$status" -ne 0 ]]; then
        echo "FAIL: 'wg-vpn up' failed to run" >&2
        echo "$output" >&2
        ufw status verbose >&2 || true
    fi
    [ "$status" -eq 0 ]

    if [[ "$HAVE_REAL_WG" -eq 1 ]]; then
        run bash -c "ip -d link show $WG_TUN_IFACE | grep -q wireguard"
        [ "$status" -eq 0 ]
    fi

    # ----- Positive paths (must succeed) -----
    # 1. Exact UDP endpoint (handshake)
    assert_udp_ok 198.51.100.2 51820

    # 2. Explicitly allowed subnet
    assert_tcp_ok 203.0.113.2 8080

    # 3. Traffic out the WireGuard interface itself
    assert_tcp_ok 192.0.2.2 8080

    # ----- Negative paths (must be blocked – the actual leak checks) -----
    # 4. Same L2 network as the endpoint, but TCP instead of the allowed
    #    UDP port.  This is the purest leak test: the destination is
    #    reachable at L2, a server is listening, yet ufw must drop it
    #    because only "allow out to ENDPOINT_IP port ENDPOINT_PORT proto udp"
    #    was installed.
    assert_tcp_blocked 198.51.100.3 8080  # IPv4
    assert_tcp_blocked 2001:db8:1::3 8080 # IPv6
    assert_udp_blocked 198.51.100.3 53    # DNS via default route (UDP/53)

    # 5. mDNS/multicast must not leak identity data out via the default
    #    route either. A listener joins 224.0.0.251:5353 on the "sub"
    #    link's far side; the allow-out-to-203.0.113.0/24 rule covers
    #    unicast traffic to that subnet only, never the multicast group
    #    address itself, so this must be dropped exactly like the other
    #    negative paths above.
    local mcast_marker="$BATS_TEST_TMPDIR/mcast_marker"
    rm -f "$mcast_marker"
    ip netns exec "$KS_NS" python3 test/integration/support/mcast_listener.py \
        224.0.0.251 5353 "$mcast_marker" 3 203.0.113.2 &
    local mcast_listener_pid=$!
    sleep 0.3

    python3 test/integration/support/mcast_probe.py 224.0.0.251 5353 wgvpn-probe 203.0.113.1
    wait "$mcast_listener_pid" 2>/dev/null || true

    if [[ -f "$mcast_marker" ]]; then
        echo "LEAK: Expected mDNS probe to be blocked, but the listener reveived it!" >&2
        cat "$mcast_marker" >&2
    fi
    [ ! -f "$mcast_marker" ]

    # Sanity: default outgoing policy is now deny
    run bash -c "ufw status verbose | grep -q 'deny (outgoing)'"
    [ "$status" -eq 0 ]
}

@test "'down' restores full connectivity and cleans state" {
    run bash -c "$WGVPN_BIN up </dev/null"
    if [[ "$status" -ne 0 ]]; then
        echo "FAIL: 'wg-vpn up' failed to run" >&2
        echo "$output" >&2
        ufw status verbose >&2 || true
    fi
    [ "$status" -eq 0 ]
    [ -f "$XDG_STATE_HOME/wg-vpn/wg-vpn.state" ]

    run bash -c "$WGVPN_BIN down </dev/null"
    if [[ "$status" -ne 0 ]]; then
        echo "FAIL: 'wg-vpn down' failed to run" >&2
        echo "$output" >&2
        ufw status verbose >&2 || true
    fi
    [ "$status" -eq 0 ]

    # State file must be gone
    [ ! -f "$XDG_STATE_HOME/wg-vpn/wg-vpn.state" ]

    # Default policy must no longer be deny
    run bash -c "! ufw status verbose | grep -q 'deny (outgoing)'"
    [ "$status" -eq 0 ]

    # Previously blocked destinations must work again
    assert_tcp_ok 198.51.100.3 8080
}

@test "'down' survives live wg config disappearing" {
    "$WGVPN_BIN" up </dev/null
    rm -f "$BATS_TEST_TMPDIR/peer.conf"

    run bash -c "$WGVPN_BIN down </dev/null"
    [ "$status" -eq 0 ]
    [ ! -f "$XDG_STATE_HOME/wg-vpn/wg-vpn.state" ]
}

@test "refuse to proceed when ufw is inactive" {
    ufw --force disable

    run bash -c "echo n | $WGVPN_BIN up"
    [ "$status" -ne 0 ]

    run ufw status
    [[ "$output" == *"inactive"* ]]
}

@test "nmcli failure triggers rollback that restores ufw" {
    export MOCK_NMCLI_UP_EXIT=1

    run bash -c "$WGVPN_BIN up </dev/null"
    [ "$status" -ne 0 ]

    # Kill-switch must not be left behind
    run bash -c "! ufw status verbose | grep -q 'deny (outgoing)'"
    [ "$status" -eq 0 ]
    [ ! -f "$XDG_STATE_HOME/wg-vpn/wg-vpn.state" ]
}
