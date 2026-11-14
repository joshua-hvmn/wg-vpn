if [[ "$ENTRYPOINT_LOADED" != "true" ]]; then
    echo "Error: This script is a component of wg-vpn and cannot be run directly."
    echo "Run 'wg-vpn [cmd]'"
    exit 1
fi

vpn_teardown() {
    local state_missing=0
    if [[ ! -f "$STATE_FILE" ]]; then
        warn "State file missing ($STATE_FILE)."
        if [[ "${NONINTERACTIVE:-}" -eq 1 ]]; then
            info "(non-interactive) attempting best-effort cleanup"
            state_missing=1
        elif yes_no "Attempt a best-effort cleanup based on default wg-vpn values to restore default internet access?"; then
            state_missing=1
        else
            die "Aborted. UFW killswitch rules remain active."
        fi
    else
        load_state_file
        get_list_from_map_file "ALLOWED_SUBNET" "$STATE_FILE" "ALLOWED_SUBNETS" || true
    fi

    info "Restoring UFW defaults and removing kill-switch rules"

    if [[ "$state_missing" -eq 1 ]]; then
        # Best effort: nothing here may exit. load_config and parse_endpoint die
        # on a config they can't use, which would leave the policy at deny, so
        # read what's there and go on to _cleanup_vpn either way.
        local wg_dir wg_file
        wg_dir=$(get_env_var WG_CONFIG_DIR "$CONFIG_FILE")
        wg_file=$(get_env_var WG_CONFIG_FILE "$CONFIG_FILE")
        CONFIG_PATH="${wg_dir%/}/${wg_file}"
        CONNECTION_NAME="${wg_file%.conf}"
        if [[ -n "$wg_file" && -f "$CONFIG_PATH" ]] && (parse_endpoint) >/dev/null 2>&1; then
            parse_endpoint
        else
            warn "No state file and no usable WireGuard config; an endpoint rule may need manual removal."
        fi
        if [[ -f "$SUBNETS_FILE" ]]; then
            get_list_from_list_file "$SUBNETS_FILE" "ALLOWED_SUBNETS" || true
        fi
    fi

    _cleanup_vpn 0
    info "VPN off, UFW killswitch rules deleted."
}

cmd_toggle_off() {
    acquire_lock exclusive
    sudo -v || die "Sudo privileges are required."
    check_deps
    vpn_teardown
}

cmd_toggle_on() {
    acquire_lock exclusive
    sudo -v || die "Sudo privileges are required."
    check_deps
    check_ufw_active
    check_ufw_ipv6

    if [[ -f "$STATE_FILE" ]]; then
        if yes_no "wg-vpn already active. Would you like to refresh the config and UFW rules?"; then
            vpn_teardown
        else
            info "Aborted."
            return 0
        fi
    fi

    load_env
    parse_endpoint
    require_numeric_endpoint
    capture_pre_vpn_state
    get_list_from_list_file "$SUBNETS_FILE" "ALLOWED_SUBNETS"

    trap rollback_on_error EXIT

    if ! nmcli connection show "$CONNECTION_NAME" >/dev/null 2>&1; then
        info "Importing connection: $CONNECTION_NAME"
        nmcli connection import type wireguard file "$CONFIG_PATH"
        nmcli connection modify "$CONNECTION_NAME" connection.description "wg-vpn-managed"

        nmcli connection modify "$CONNECTION_NAME" ipv4.dns-priority -1
        nmcli connection modify "$CONNECTION_NAME" ipv6.dns-priority -1
        nmcli connection modify "$CONNECTION_NAME" ipv4.dns-search "~."
        nmcli connection modify "$CONNECTION_NAME" ipv6.dns-search "~."
    else
        info "Connection $CONNECTION_NAME already imported, skipping..."
    fi

    write_initial_state

    info "Applying UFW killswitch"
    # The endpoint rule goes in before the default deny, so the handshake is
    # never blocked
    sudo ufw allow out to "$ENDPOINT_IP" port "$ENDPOINT_PORT" proto udp
    sudo ufw default deny outgoing
    flush_established_flows

    info "Bringing connection up"
    if ! nmcli connection up "$CONNECTION_NAME"; then
        die "Failed to bring up VPN connection."
    fi

    update_state_interface

    sudo ufw allow out on "$WG_IFACE"

    for subnet in "${ALLOWED_SUBNETS[@]}"; do
        sudo ufw allow out to "$subnet"
    done

    sudo ufw reload
    info "VPN + killswitch active ($CONNECTION_NAME on $WG_IFACE)"

    trap - EXIT
}

cmd_toggle_switch() {
    acquire_lock exclusive
    if [[ -f "$STATE_FILE" ]]; then
        info "VPN is currently ON. Turning OFF..."
        cmd_toggle_off
    else
        info "VPN is currently OFF. Turning ON..."
        cmd_toggle_on
    fi
}
