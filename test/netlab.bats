#!/usr/bin/env bats
#
# killswitch.bats stands entirely on this contract:
#
#   0  the traffic got through
#   1  the firewall stopped it
#   2  the probe never ran
#
#   'blocked' must never exit 2

setup() {
	command -v python3 >/dev/null 2>&1 || skip "python3 is not installed"

	NETLAB="$BATS_TEST_DIRNAME/integration/support/netlab.py"
	[[ -f "$NETLAB" ]] || skip "netlab.py not found at $NETLAB"

	PORT=$((20000 + RANDOM % 20000))
	SERVER_PID=""
}

teardown() {
	[[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null
	return 0
}

# Start an echo server on loopback and wait until it reports itself bound
start_server() {
	local kind="$1"
	python3 "$NETLAB" "serve-$kind" 127.0.0.1 "$PORT" \
		--ready "$BATS_TEST_TMPDIR/ready" >"$BATS_TEST_TMPDIR/log" 2>&1 &
	SERVER_PID=$!
	wait_for_file "$BATS_TEST_TMPDIR/ready" || {
		cat "$BATS_TEST_TMPDIR/log" >&2
		return 1
	}
}

wait_for_file() {
	local deadline=$((SECONDS + 10))
	until [[ -f "$1" ]]; do
		((SECONDS < deadline)) || return 1
		sleep 0.05
	done
}

# ---------------------------------------------------------------------------------

@test "netlab: tcp exits 0 when the traffic gets through" {
	start_server tcp

	run python3 "$NETLAB" tcp 127.0.0.1 "$PORT"
	[ "$status" -eq 0 ]
}

@test "netlab: tcp exits 1 when nothing is listening" {
	run python3 "$NETLAB" tcp 127.0.0.1 "$PORT"
	[ "$status" -eq 1 ]
}

@test "netlab: udp exits 0 when the datagram comes back" {
	start_server udp

	run python3 "$NETLAB" udp 127.0.0.1 "$PORT"
	[ "$status" -eq 0 ]
}

@test "netlab: udp exits 1 when nothing answers" {
	run python3 "$NETLAB" udp 127.0.0.1 "$PORT" --timeout 0.5
	[ "$status" -eq 1 ]
}

@test "netlab: a probe that cannot run exits 2, not 1" {
	run python3 "$NETLAB" tcp wg-vpn-no-such-host.invalid 80
	[ "$status" -eq 2 ]
}

@test "netlab: a listener that cannot bind exits 2, not 0" {
	run python3 "$NETLAB" serve-tcp 203.0.113.99 "$PORT" --ready "$BATS_TEST_TMPDIR/ready"
	[ "$status" -eq 2 ]
	[ ! -f "$BATS_TEST_TMPDIR/ready" ]
}

@test "netlab: hold-tcp exits 0 while the flow lives and 1 once it is cut" {
	start_server tcp
	local ready="$BATS_TEST_TMPDIR/held.ready"
	local go="$BATS_TEST_TMPDIR/held.go"
	local held rc

	python3 "$NETLAB" hold-tcp 127.0.0.1 "$PORT" --ready "$ready" --go "$go" --wait 20 &
	held=$!
	wait_for_file "$ready"
	touch "$go"
	rc=0
	wait "$held" || rc=$?
	[ "$rc" -eq 0 ]

	rm -f "$ready" "$go"
	python3 "$NETLAB" hold-tcp 127.0.0.1 "$PORT" \
		--ready "$ready" --go "$go" --wait 20 --timeout 1 &
	held=$!
	wait_for_file "$ready"
	kill "$SERVER_PID"
	SERVER_PID=""
	touch "$go"
	rc=0
	wait "$held" || rc=$?
	[ "$rc" -eq 1 ]
}
