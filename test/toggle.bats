setup() {
	load 'test_helper'
	setup_mocks
}

teardown() {
	:
}

@test "wg-vpn up applies ufw killswitch and starts nmcli" {
	# Override nmcli mock
	cat >"$MOCK_BIN_DIR/nmcli" <<'EOF'
#!/usr/bin/env bash
echo "nmcli $*" >> "$MOCK_LOG"
# 1. Always succed and output wg0 for iface checks
if [[ "$*" == *"GENERAL.DEVICES"* ]]
	echo "wg0"
	exit 0
fi

# 2. Fail connection check only if not imported
if [[ "$1" == "connection" && "$2" == "show" ]]; then
	if grep -q "connection import" "$MOCK_LOG"; then
		exit 0
	else
		exit 1
	fi
fi

exit 0
EOF
	chmod +x "$MOCK_BIN_DIR/nmcli"

	run ./wg-vpn up
	if [ "$status" -ne 0 ]; then
		echo "--- wg-vpn up failed with status $status ---" >&3
		echo "Output: $output" >&3
		echo "Mock log:" >&3
		cat "$MOCK_LOG" >&3
	fi
	[ "$status" -eq 0 ]

	assert_log "nmcli connection import type wireguard"
	assert_log "sudo ufw default deny outgoing"
	assert_log "sudo ufw allow out to 198.51.100.1 port 51820 proto udp"
	assert_log "sudo ufw allow out to 10.0.0.0/8"
	assert_log "sudo ufw allow out to 172.16.0.0/12"
	assert_log "sudo ufw allow out to 192.168.0.0/16"
	assert_log "nmcli connection up test-vpn"
	assert_log "sudo ufw allow out on wg0"
}

@test "wg-vpn down restores previous network state" {
	mkdir -p "$XDG_STATE_HOME/wg-vpn"
	cat >"$XDG_STATE_HOME/wg-vpn/wg-vpn.state" <<EOF
ENDPOINT_IP="198.51.100.1"
ENDPOINT_PORT="51820"
CONNECTION_NAME="test-vpn"
WG_IFACE="wg0"
PREV_UFW_POLICY="allow"
PREV_IPV6_STATE=0
ALLOWED_SUBNET="192.168.1.0/24"
EOF

	run ./wg-vpn down
	if [ "$status" -ne 0 ]; then
		echo "--- wg-vpn down failed with status $status ---" >&3
		echo "Output: $output" >&3
		echo "Mock log:" >&3
		cat "$MOCK_LOG" >&3
	fi
	[ "$status" -eq 0 ]

	assert_log "nmcli connection down test-vpn"
	assert_log "sudo ufw delete allow out to 198.51.100.1 port 51820 proto udp"
	assert_log "sudo ufw delete allow out to 192.168.1.0/24"
	assert_log "sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0"
	assert_log "sudo sysctl -w net.ipv6.conf.default.disable_ipv6=0"
	assert_log "sudo ufw default allow outgoing"
}

@test "wg-vpn triggers rollback if nmcli up fails" {
	# Override nmcli mock to force up to fail
	cat >"$MOCK_BIN_DIR/nmcli" <<'EOF'
#!/usr/bin/env bash
echo "nmcli $*" >> "$MOCK_LOG"
# 1. Always succed and output wg0 for iface checks
if [[ "$*" == *"GENERAL.DEVICES"* ]]
	echo "wg0"
	exit 0
fi

if [[ "$1" == "connection" && "$2" == "up" ]]; then
	exit 1
fi

# 2. Fail connection check only if not imported
if [[ "$1" == "connection" && "$2" == "show" ]]; then
	if grep -q "connection import" "$MOCK_LOG"; then
		exit 0
	else
		exit 1
	fi
fi

exit 0
EOF

	chmod +x "$MOCK_BIN_DIR/nmcli"

	run ./wg-vpn up
	if [ "$status" -ne 1 ]; then
		echo "--- wg-vpn up expected status 1 but got $status ---" >&3
		echo "Output: $output" >&3
		echo "Mock log:" >&3
		cat "$MOCK_LOG" >&3
	fi
	[ "$status" -eq 1 ]

	assert_log "nmcli connection delete test-vpn"
	assert_log "sudo ufw default allow outgoing"
}
