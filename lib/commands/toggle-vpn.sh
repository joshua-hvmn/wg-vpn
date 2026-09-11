if [[ "$ENTRYPOINT_LOADED" != "true" ]]; then
    echo "Error: This script is a component of wg-vpn and cannot be run directly."
    echo "Run 'wg-vpn [cmd]'"
    exit 1
fi

vpn_teardown() {
    local state_missing=0
    if [[ ! -f "$STATE_FILE" ]]; then
        info "Warning: State file missing ($STATE_FILE)."
        if yes_no "Attempt a best-effort cleanup based on default wg-vpn values to restore default internet access?"; then
            state_missing=1
        else
            die "Aborted. UFW killswitch rules remain active."
        fi
    else
        load_state_file
    fi

    if [[ "$state_missing" -eq 1 ]]; then
        load_env
        parse_endpoint || true
    fi

    info "Bringing connection down"
    if is_managed_connection "$CONNECTION_NAME"; then
        nmcli connection delete "$CONNECTION_NAME" 2>/dev/null || true
    else
        info "Connection '$CONNECTION_NAME' was not created by wg-vpn; leaving it in place."
    fi

    info "Restoring UFW defaults"

    if [[ -n "${ENDPOINT_IP:-}" && -n "${ENDPOINT_PORT:-}" ]]; then
        sudo ufw delete allow out to "$ENDPOINT_IP" port "$ENDPOINT_PORT" proto udp 2>/dev/null || true
    fi

    if [[ -n "${WG_IFACE:-}" ]]; then
        sudo ufw delete allow out on "$WG_IFACE" 2>/dev/null || true
    fi

    if [[ "$state_missing" -eq 0 ]]; then
        get_list_from_map_file "ALLOWED_SUBNET" "$STATE_FILE" "ALLOWED_SUBNETS"
    fi

    if [[ "${#ALLOWED_SUBNETS[@]}" -eq 0 && -f "$SUBNETS_FILE" ]]; then
        info "Falling back to subnets file for cleanup..."
        get_list_from_list_file "$SUBNETS_FILE" "ALLOWED_SUBNETS"
    fi

    for subnet in "${ALLOWED_SUBNETS[@]}"; do
        sudo ufw delete allow out to "$subnet" 2>/dev/null || true
    done

    if [[ -n "${PREV_UFW_POLICY:-}" ]]; then
        sudo ufw default "$PREV_UFW_POLICY" outgoing
    else
        info "No previous UFW policy found. Defaulting to 'allow' outgoing."
        sudo ufw default allow outgoing
    fi

    sudo ufw reload

    if [[ "$state_missing" -eq 0 ]]; then
        info "Removing state file"
        rm -f "$STATE_FILE"
    fi

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
    # allow handshake to vpn before denying traffic to allow ufw to resolve IP if given a domain name
    sudo ufw allow out to "$ENDPOINT_IP" port "$ENDPOINT_PORT" proto udp
    sudo ufw default deny outgoing

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
