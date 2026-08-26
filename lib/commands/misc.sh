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
    nmcli -f GENERAL.STATE,IP4.ADDRESS,IP6.ADDRESS connection show "$CONNECTION_NAME" 2>/dev/null ||
        echo "(connection not present)"
    echo
    echo "UFW status (outgoing default):"
    sudo ufw status | head -20
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [command]

Commands:
  on, up        Import/activate WireGuard + enable UFW kill-switch
  off, down     Deactivate WireGuard + restore outgoing traffic
  toggle        Switch between on/off automatically (Default)
  status, ps    Show current state

Configuration lives in:
  $CONFIG_FILE
EOF
}
