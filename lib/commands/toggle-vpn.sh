if [[ "$ENTRYPOINT_LOADED" != "true" ]]; then
    echo "Error: This script is a component of wg-vpn and cannot be run directly."
    echo "Run 'wg-vpn [cmd]'"
    exit 1
fi

cmd_toggle_on() {
    acquire_lock exclusive
    sudo -v || die "Sudo privileges are required."
    check_deps
    load_env
    parse_endpoint
    capture_pre_vpn_state
    CONNECTION_IMPORTED=0

    trap rollback_on_error EXIT

    if ! nmcli connection show "$CONNECTION_NAME" >/dev/null 2>&1; then
        info "Importing connection: $CONNECTION_NAME"
        nmcli connection import type wireguard file "$CONFIG_PATH"
        CONNECTION_IMPORTED=1
        export CONNECTION_IMPORTED
        nmcli connection modify "$CONNECTION_NAME" ipv4.dns-priority -1
        nmcli connection modify "$CONNECTION_NAME" ipv6.dns-priority -1
    else
        info "Connection $CONNECTION_NAME already imported, skipping..."
    fi

    info "Applying UFW killswitch"
    # allow handshake to vpn before denying traffic to allow ufw to resolve IP if given a domain name
    sudo ufw allow out to "$ENDPOINT_IP" port "$ENDPOINT_PORT" proto udp
    # set default deny policy
    sudo ufw default deny outgoing
    disable_ipv6 1

    info "Bringing connection up"
    if ! nmcli connection up "$CONNECTION_NAME"; then
        die "Failed to bring up VPN connection."
    fi

    write_state_file

    # allow all traffic out on the vpn
    sudo ufw allow out on "$WG_IFACE"

    # local/private ranges
    for subnet in "${ALLOWED_SUBNETS[@]}"; do
        sudo ufw allow out to "$subnet"
    done

    sudo ufw reload
    info "VPN + killswitch active ($CONNECTION_NAME on $WG_IFACE)"

    trap - EXIT
}

cmd_toggle_off() {
    acquire_lock exclusive
    sudo -v || die "Sudo privileges are required."
    check_deps
    load_env

    if [[ ! -f "$STATE_FILE" ]]; then
        die "State file missing ($STATE_FILE). Cannot safely determine which UFW rules to delete."
    fi

    load_state_file

    info "Bringing connection down"
    nmcli connection down "$CONNECTION_NAME" 2>/dev/null || true

    info "Restoring UFW defaults"
    sudo ufw delete allow out to "$ENDPOINT_IP" port "$ENDPOINT_PORT" proto udp 2>/dev/null || true
    sudo ufw delete allow out on "$WG_IFACE" 2>/dev/null || true

    if [[ -n "${PREV_IPV6_STATE:-}" ]]; then
        disable_ipv6 "$PREV_IPV6_STATE"
    else
        disable_ipv6 0
    fi

    get_env_array "ALLOWED_SUBNET" "$STATE_FILE" "ALLOWED_SUBNETS"

    for subnet in "${ALLOWED_SUBNETS[@]}"; do
        sudo ufw delete allow out to "$subnet" 2>/dev/null || true
    done

    if [[ -n "${PREV_UFW_POLICY:-}" ]]; then
        sudo ufw default "$PREV_UFW_POLICY" outgoing
    else
        sudo ufw default allow outgoing
    fi

    sudo ufw reload

    info "Removing state file"
    rm -f "$STATE_FILE"

    info "VPN off, UFW killswitch rules deleted."
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
