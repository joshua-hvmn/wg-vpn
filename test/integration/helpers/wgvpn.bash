#!/usr/bin/env bash
# shellcheck shell=bash
#
# Mocks nmcli and sudo:
#
#   nmcli  there is no NetworkManager and no real VPN provider in the lab,
#          so the mock reports the interface the lab actually built
#   sudo   the suite already runs as root; the mock answers `sudo -v` and
#          then gets out of the way, so every `sudo ufw ...` really runs
#
# Everything else is real

wgvpn_workspace() {
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
    export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
    mkdir -p "$XDG_CONFIG_HOME/wg-vpn" "$XDG_STATE_HOME/wg-vpn"

    WGVPN_BIN="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/wg-vpn"
    # shellcheck disable=SC2034  # read by the spec and the assertions
    WGVPN_STATE_FILE="$XDG_STATE_HOME/wg-vpn/wg-vpn.state"
    WGVPN_WG_CONFIG="$BATS_TEST_TMPDIR/peer.conf"
    WGVPN_MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
    : >"$WGVPN_MOCK_LOG"

    cat >"$XDG_CONFIG_HOME/wg-vpn/wg-vpn.conf" <<EOF
WG_CONFIG_DIR="$BATS_TEST_TMPDIR"
WG_CONFIG_FILE="peer.conf"
EOF

    cat >"$WGVPN_WG_CONFIG" <<EOF
[Interface]
PrivateKey = dummyprivatekey=
Address = $LAB_TUN_TARGET/32

[Peer]
PublicKey = dummypublickey=
Endpoint = $LAB_EP_IP:$LAB_EP_PORT
EOF

    cat >"$XDG_CONFIG_HOME/wg-vpn/subnets.list" <<'EOF'
203.0.113.0/24
EOF

    wgvpn_install_mocks
}

wgvpn_install_mocks() {
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"

    cat >"$bin/nmcli" <<EOF
#!/usr/bin/env bash
printf 'nmcli %s\n' "\$*" >>"$WGVPN_MOCK_LOG"
case "\$*" in
*"GENERAL.DEVICES"*)        echo "$LAB_TUN_IFACE" ;;
*"connection.description"*) echo "wg-vpn-managed" ;;
*"connection up"*)          exit "\${MOCK_NMCLI_UP_EXIT:-0}" ;;
*"connection show"*)        exit 1 ;;  # nothing is imported yet
*)                          exit 0 ;;
esac
EOF

    cat >"$bin/sudo" <<EOF
#!/usr/bin/env bash
printf 'sudo %s\n' "\$*" >>"$WGVPN_MOCK_LOG"
[[ "\$1" == "-v" ]] && exit 0   # credential refresh only
exec "\$@"
EOF

    chmod +x "$bin/nmcli" "$bin/sudo"
    export PATH="$bin:$PATH"
}

## Run wg-vpn with no one at the keyboard.
#  Anything that prompts here is a bug in its own right: this is the path a
#  systemd unit or a shell script would take.
wgvpn() {
    "$WGVPN_BIN" "$@" </dev/null
}

## Run wg-vpn and answer its first prompt.
wgvpn_answer() {
    local reply="$1"
    shift
    printf '%s\n' "$reply" | "$WGVPN_BIN" "$@"
}
