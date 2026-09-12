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
#   ep pair   (198.51.100.0/24) – the specific endpoint allow rule
#   tun pair  (192.0.2.0/24)    – the allow-out-on-<iface> rule
#   sub pair  (203.0.113.0/24)  – the allow-out-to-<subnet> rule
#
# subnets.list is set explicitly to 203.0.113.0/24 only, so this test
# never depends on (or collides with) the default RFC1918 seed list.
#
# After `up` the test asserts both the positive paths (allowed traffic)
# AND the negative paths (everything else must be blocked).  That is the
# actual leak check.
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
	ip link set wgt-ep up
	ip netns exec "$KS_NS" ip addr add 198.51.100.2/24 dev wgt-ep-far
	ip netns exec "$KS_NS" ip addr add 198.51.100.3/24 dev wgt-ep-far
	ip netns exec "$KS_NS" ip link set wgt-ep-far up

	# Tunnel-interface veth pair (name reported by the nmcli mock's GENERAL.DEVICES)
	ip link add wgt-tun type veth peer name wgt-tun-far
	ip link set wgt-tun-far netns "$KS_NS"
	ip addr add 192.0.2.1/24 dev wgt-tun
	ip link set wgt-tun up
	ip netns exec "$KS_NS" ip addr add 192.0.2.2/24 dev wgt-tun-far
	ip netns exec "$KS_NS" ip link set wgt-tun-far up

	# Allowed-subnet veth pair
	ip link add wgt-sub type veth peer name wgt-sub-far
	ip link set wgt-sub-far netns "$KS_NS"
	ip addr add 203.0.113.1/24 dev wgt-sub
	ip link set wgt-sub up
	ip netns exec "$KS_NS" ip addr add 203.0.113.2/24 dev wgt-sub-far
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
	sleep 0.3

	if [[ -f /etc/default/ufw ]]; then
		grep -q '^IPV6=yes' /etc/default/ufw || sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
	fi
	ufw --force reset >/dev/null 2>&1 || true
	ufw --force enable >/dev/null 2>&1
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

	MOCK_BIN_DIR="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$MOCK_BIN_DIR"

	# nmcli is fully mocked – we never bring up a real WireGuard interface
	cat >"$MOCK_BIN_DIR/nmcli" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*"GENERAL.DEVICES"*)        echo "wgt-tun" ;;
*"connection.description"*) echo "wg-vpn-managed" ;;
*"connection import"*)      exit 0 ;;
*"connection modify"*)      exit 0 ;;
*"connection up"*)          exit "${MOCK_NMCLI_UP_EXIT:-0}" ;;
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
}

teardown() {
	ufw --force reset >/dev/null 2>&1 || true
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
		echo "Expected TCP $host:$port to SUCCEED, but it failed" >&2
	fi
	[ "$status" -eq 0 ]
}

# Assert that a TCP connect is blocked (status != 0)
assert_tcp_blocked() {
	local host="$1" port="$2"
	run python3 test/integration/support/tcp_probe.py "$host" "$port"
	if [[ "$status" -eq 0 ]]; then
		echo "Expected TCP $host:$port to be BLOCKED, but it succeeded (leak!)" >&2
	fi
	[ "$status" -ne 0 ]
}

# Assert that the UDP endpoint handshake works
assert_udp_ok() {
	local host="$1" port="$2"
	run python3 test/integration/support/udp_probe.py "$host" "$port"
	if [[ "$status" -ne 0 ]]; then
		echo "Expected UDP $host:$port to SUCCEED, but it failed" >&2
	fi
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "'up' installs kill-switch: allowed paths work, everything else is blocked" {
	run bash -c "$WGVPN_BIN up </dev/null"
	if [[ "$status" -ne 0 ]]; then
		echo "--- wg-vpn up failed ---" >&2
		echo "$output" >&2
		ufw status verbose >&2 || true
	fi
	[ "$status" -eq 0 ]

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
	assert_tcp_blocked 198.51.100.3 8080

	# Sanity: default outgoing policy is now deny
	run bash -c "ufw status verbose | grep -q 'deny (outgoing)'"
	[ "$status" -eq 0 ]
}

@test "'down' restores full connectivity and cleans state" {
	run bash -c "$WGVPN_BIN up </dev/null"
	if [[ "$status" -ne 0 ]]; then
		echo "--- up failed (unexpected) ---" >&2
		echo "$output" >&2
		ufw status verbose >&2 || true
	fi
	[ "$status" -eq 0 ]
	[ -f "$XDG_STATE_HOME/wg-vpn/wg-vpn.state" ]

	# Show what we captured so we can debug policy restore
	echo "--- state file after up ---" >&2
	cat "$XDG_STATE_HOME/wg-vpn/wg-vpn.state" >&2 || true

	run bash -c "$WGVPN_BIN down </dev/null"
	if [[ "$status" -ne 0 ]]; then
		echo "--- down failed ---" >&2
		echo "$output" >&2
	fi
	[ "$status" -eq 0 ]

	# State file must be gone
	[ ! -f "$XDG_STATE_HOME/wg-vpn/wg-vpn.state" ]

	# Default policy must no longer be deny
	run bash -c "ufw status verbose"
	echo "--- ufw status after down ---" >&2
	echo "$output" >&2
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
	if [[ "$status" -eq 0 ]]; then
		echo "--- up unexpectedly succeeded ---" >&2
		echo "$output" >&2
	fi
	[ "$status" -ne 0 ]

	run bash -c "ufw status verbose"
	echo "--- ufw status after failed up / rollback ---" >&2
	echo "$output" >&2
	run bash -c "! ufw status verbose | grep -q 'deny (outgoing)'"
	if [[ "$status" -ne 0 ]]; then
		echo "LEAK: outgoing policy still deny after rollback" >&2
	fi
	[ "$status" -eq 0 ]
	[ ! -f "$XDG_STATE_HOME/wg-vpn/wg-vpn.state" ]
}
