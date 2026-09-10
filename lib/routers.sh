if [[ "$ENTRYPOINT_LOADED" != "true" ]]; then
    echo "Error: This script is a component of wg-vpn and cannot be run directly."
    echo "Run 'wg-vpn [cmd]'"
    exit 1
fi
process_command() {
    local cmd="$1"
    shift || true
    case "$cmd" in
    on | up)
        cmd_toggle_on "$@"
        ;;
    off | down)
        cmd_toggle_off "$@"
        ;;
    "" | toggle)
        cmd_toggle_switch "$@"
        ;;
    -st | --status | status | ps)
        cmd_status "$@"
        ;;
    -h | --help | help | usage)
        usage "$@"
        ;;
    init | --init-config)
        cmd_config init
        ;;
    config | --configure)
        cmd_config "$@"
        ;;
    *)
        die "unknown command: $cmd"
        ;;
    esac
}
