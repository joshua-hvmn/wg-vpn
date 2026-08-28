setup_mocks() {
    # Create an isolated environment for config and state
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
    export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
    mkdir -p "$XDG_CONFIG_HOME/wg-vpn" "$XDG_STATE_HOME/wg-vpn"

    # Create dummy wg-vpn.conf so script passes init checks
    cat >"$XDG_CONFIG_HOME/wg-vpn/wg-vpn.conf" <<EOF
WG_CONFIG_DIR="$BATS_TEST_TMPDIR"
WG_CONFIG_FILE="test-vpn.conf"
EOF

    # dummy wg config
    touch "$BATS_TEST_TMPDIR/test-vpn.conf"
    cat >"$BATS_TEST_TMPDIR/test-vpn.conf" <<EOF
[Interface]
PrivateKey = dummyprivatekey=
Address = 10.0.0.2/32

[Peer]
PublicKey = dummypublickey=
Endpoint = 198.51.100.1:51820
EOF

    # Set up mock bin dir
    export MOCK_BIN_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$MOCK_BIN_DIR"
    export PATH="$MOCK_BIN_DIR:$PATH"

    export MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
    touch "$MOCK_LOG"

    # Create mock commands
    for cmd in sudo nmcli ufw flock sysctl ip; do
        cat <<EOF >"$MOCK_BIN_DIR/$cmd"
#!/usr/bin/env bash
echo "$cmd \$*" >> "$MOCK_LOG"
# Fake nmcli returning an interface name for write_state_file
if [[ "$cmd" == "nmcli" && "\$*" == *"GENERAL.DEVICES"* ]]; then
    echo "wg0"
fi
EOF
        chmod +x "$MOCK_BIN_DIR/$cmd"
    done
}

# Assert a substring appears in the mock log
assert_log() {
    local target="$1"
    if ! grep -qF -- "$target" "$MOCK_LOG"; then
        echo "ERROR: expected log entry not found: $target" >&3
        echo "--- Mock Log Contents ---" >&3
        cat "$MOCK_LOG" >&3
        return 1
    fi
}

# Assert a substring does NOT appear
assert_not_log() {
    local target="$1"
    if grep -qF -- "$target" "$MOCK_LOG"; then
        echo "ERROR: unexpected log entry found: $target" >&3
        echo "--- Mock Log Contents ---" >&3
        cat "$MOCK_LOG" >&3
        return 1
    fi
}
