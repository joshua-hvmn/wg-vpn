if [[ "$ENTRYPOINT_LOADED" != "true" ]]; then
    echo "Error: This script is a component of wg-vpn and cannot be run directly."
    echo "Run 'wg-vpn [cmd]'"
    exit 1
fi
process_command() {
    case "$1" in
    on | up)
        cmd_toggle_on
        ;;
    off | down)
        cmd_toggle_off
        ;;
    "" | toggle)
        cmd_toggle_switch
        ;;
    -st | --status | status | ps)
        cmd_status
        ;;
    -h | --help | help | usage)
        usage
        ;;
    init | --init-config)
        cmd_init_config_files
        ;;
    *)
        die "unknown command: $1"
        ;;
    esac
}
