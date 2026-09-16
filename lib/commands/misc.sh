if [[ "$ENTRYPOINT_LOADED" != "true" ]]; then
    echo "Error: This script is a component of wg-vpn and cannot be run directly."
    echo "Run 'wg-vpn [cmd]'"
    exit 1
fi

cmd_status() {
    acquire_lock shared
    check_deps
    load_env
    echo "Config dir  : $WG_CONFIG_DIR"
    echo "Config file : $WG_CONFIG_FILE"
    echo "Connection  : $CONNECTION_NAME"
    echo
    if [[ -f "$STATE_FILE" ]]; then
        echo "State       : active (kill-switch armed)"
        # shellcheck disable=SC1090
        source <(grep -E '^(WG_IFACE|ENDPOINT_IP|ENDPOINT_PORT)=' "$STATE_FILE" 2>/dev/null || true)
        [[ -n "${WG_IFACE:-}" ]] && echo "Interface   : $WG_IFACE"
        [[ -n "${ENDPOINT_IP:-}" ]] && echo "Endpoint    : ${ENDPOINT_IP}:${ENDPOINT_PORT:-}"
    else
        echo "State       : inactive"
    fi
    echo
    nmcli -f GENERAL.STATE,IP4.ADDRESS,IP6.ADDRESS connection show "$CONNECTION_NAME" 2>/dev/null ||
        echo "(connection not present)"
    echo
    echo "UFW status (outgoing default):"
    sudo ufw status | head -20
}

cmd_version() {
    local ver="unknown"
    if [[ -f "$LIB_DIR/../VERSION" ]]; then
        ver=$(tr -d '[:space:]' <"$LIB_DIR/../VERSION")
    elif [[ -f "$(dirname "$LIB_DIR")/VERSION" ]]; then
        ver=$(tr -d '[:space:]' <"$(dirname "$LIB_DIR")/VERSION")
    fi
    printf 'wg-vpn %s\n' "$ver"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [command]

Commands:
  on, up        Import/activate WireGuard + enable UFW kill-switch
  off, down     Deactivate WireGuard + restore outgoing traffic
  toggle        Switch between on/off automatically (Default)
  status, ps    Show current state
  config        Manage WireGuard config path and allowed subnets
  init          Initialize configuration files
  version       Print version

Configuration lives in:
  $CONFIG_FILE
EOF
}
