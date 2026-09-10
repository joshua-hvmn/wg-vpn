if [[ "$ENTRYPOINT_LOADED" != "true" ]]; then
    echo "Error: This script is a component of wg-vpn and cannot be run directly."
    echo "Run 'wg-vpn [cmd]'"
    exit 1
fi

# DATA/STATE LAYER

## Guided first-time / repair setup for wg-vpn.conf and subnets.list
# USAGE: init_config
init_config() {
    local is_first_run=0
    local needs_setup=0

    if [[ ! -f "$CONFIG_FILE" ]]; then
        is_first_run=1
        needs_setup=1
        info "First run detected / Config Missing."
        info "Initializing configuration."
    else
        for key in "${!ENV_VARS[@]}"; do
            if [[ -z "$(get_env_var "$key" "$CONFIG_FILE")" ]]; then
                needs_setup=1
                info "Configuration exists but is missing required variable: $key"
            fi
        done
    fi

    [[ "$needs_setup" -eq 0 ]] && return 0

    mkdir -p "$CONFIG_DIR" || die "Could not create config directory: $CONFIG_DIR"

    if yes_no "Would you like to configure wg-vpn now?"; then
        mkdir -p "${CONFIG_FILE%/*}"

        for key in "${!ENV_VARS[@]}"; do
            local desc="${ENV_VARS[$key]}"
            local current_val=""

            [[ "$is_first_run" -eq 0 ]] && current_val=$(get_env_var "$key" "$CONFIG_FILE")

            local prompt_suffix=""
            [[ -n "$current_val" ]] && prompt_suffix=" [$current_val]"

            local user_val
            read -r -p "Enter $desc${prompt_suffix}: " user_val

            user_val="${user_val:-$current_val}"

            if [[ -n "$user_val" ]]; then
                edit_kv "$key" "$user_val" "$CONFIG_FILE"
            fi
        done
        info "Configuration saved to $CONFIG_FILE"
    else
        # Create skeleton config
        if [[ ! -f "${CONFIG_FILE:-}" ]]; then
            cat >"$CONFIG_FILE" <<EOF
# wg-vpn configuration
# fill in the values below, and run wg-vpn on

WG_CONFIG_DIR=
WG_CONFIG_FILE=
EOF
            info "Created empty config at $CONFIG_FILE"
            info "Edit it manually, then run 'wg-vpn', or run 'wg-vpn' again to be prompted again."
        fi
    fi

    ensure_subnets_file
}

# Ensure base config files exist without init_config so config is not interactive
_ensure_config_files() {
    [[ -d "$CONFIG_DIR" ]] || mkdir -p "$CONFIG_DIR"
    [[ -f "$CONFIG_FILE" ]] || touch -- "$CONFIG_FILE"
    ensure_subnets_file
}

_edit_list_file() {
    local action="$1"
    local value="$2"
    local target="$3"

    [[ -f "$target" ]] || touch -- "$target"
    local tmp
    tmp=$(make_temp "$target") || die "Failed to create temp file for $target"

    case "$action" in
    rm)
        grep -v -F -x "$value" "$target" >"$tmp" || true
        ;;
    add)
        cp "$target" "$tmp"
        if ! grep -q -F -x "$value" "$target"; then
            [[ -s "$tmp" && "$(tail -c 1 "$tmp" 2>/dev/null)" != $'\n' ]] && printf '\n' >>"$tmp"
            printf '%s\n' "$value" >>"$tmp"
        fi
        ;;
    esac

    local perms
    perms=$(stat -c %a "$target" 2>/dev/null || printf '600')
    chmod "$perms" "$tmp"
    mv -f -- "$tmp" "$target"
}

# UI LAYER

# Render a selection menu for .conf files in a dir
_interactive_wg_select() {
    local dir="$1"
    [[ -d "$dir" ]] || {
        error "directory not found : $dir"
        return 1
    }

    local config_paths=()
    while IFS= read -r path; do
        [[ -n "$path" ]] && config_paths+=("$path")
    done < <(find "$dir" -maxdepth 1 -type f -name '*.conf' ! -name '.*' 2>/dev/null | sort)

    local count=${#config_paths[@]}
    [[ "$count" -eq 0 ]] && {
        error "no .conf files found in $dir"
        return 1
    }

    echo ""
    info "Available configs in $dir:"
    local i=1
    for cfg in "${config_paths[@]}"; do
        printf " %2d. %s\n" "$i" "$(basename "$cfg")"
        ((i++))
    done
    echo "-------------------------------------------"

    while true; do
        read -r -p "Select config [1-$count, x to cancel]: " sel || break
        case "${sel,,}" in
        x | c)
            info "Selection cancelled."
            return 0
            ;;
        *)
            if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= count)); then
                local chosen="${config_paths[$((sel - 1))]}"
                local filename
                filename="$(basename "$chosen")"
                edit_kv "WG_CONFIG_FILE" "$filename" "$CONFIG_FILE"
                info "Config file updated to: $filename"
                return 0
            else
                echo "Invalid selection." >&2
            fi
            ;;
        esac
    done
}

# Sets WG_CONFIG_DIR to input path then runs file selection.
_set_wg_dir_and_select() {
    local dir="$1"
    edit_kv "WG_CONFIG_DIR" "$dir" "$CONFIG_FILE"
    info "WG_CONFIG_DIR set to: $dir"
    _interactive_wg_select "$dir" || true
}

# Manual fallback
_cmd_config_wg_menu() {
    while true; do
        local current_dir current_file
        load_env
        current_dir="${WG_CONFIG_DIR}"
        current_file="${WG_CONFIG_FILE}"

        echo ""
        info "Current WireGuard Configuration:"
        echo "  Directory : ${current_dir:-[Not set]}"
        echo "  File      : ${current_file:-[Not set]}"
        echo "-------------------------------------------"
        echo "  1. Change Config Directory"
        echo "  2. Select Config File"
        echo "  x. Exit"
        echo "-------------------------------------------"

        read -r -p "Choice: " choice || break
        case "${choice,,}" in
        1)
            local new_dir
            read -r -p "Enter new directory path: " new_dir
            if [[ -d "${new_dir:-}" ]]; then
                new_dir="$(cd "$new_dir" && pwd)"
                edit_kv "WG_CONFIG_DIR" "$new_dir" "$CONFIG_FILE"
                info "Directory installed."
            else
                echo "Invalid or inaccessible directory." >&2
            fi
            ;;
        2)
            if [[ -n "$current_dir" && -d "$current_dir" ]]; then
                _interactive_wg_select "$current_dir" || true
            else
                echo "Please set a valid config directory first." >&2
            fi
            ;;
        x)
            return 0
            ;;
        *)
            echo "Invalid choice." >&2
            ;;
        esac
    done
}

_cd_config_menu() {
    while true; do
        echo ""
        info "wg-vpn Configuration"
        echo "  1. WireGuard config (directory and file)"
        echo "  2. Allowed subnets"
        echo "  x. Exit"
        echo "-------------------------------------------"
        read -r -p "Choice: " choice || break
        case "${choice,,}" in
        1) cmd_config_wg ;;
        2) cmd_config_subnets ;;
        x | c) return 0 ;;
        *) echo "Invalid choice." >&2 ;;
        esac
    done
}

usage_config() {
    cat <<EOF
Usage: wg-vpn config <command> [args...]

Commands:
  wg [dir|.conf]           Configure WireGuard config directory or default file.
  subnets [ip/cidr] [rm]   Manage local subnets that bypass the VPN killswitch.
  init                     (Re)run guided setup of wg-vpn.conf and subnets.list.

wg flags (used instead of [dir|.conf], no other args):
  -y        Skip the "\$PWD" prompt: set the dir to the current directory and
            go straight to config file selection.
  --silent  Same as -y, but sets the dir and returns with no output or
            file selection. Useful for scripting.

Examples:
  wg-vpn config                            (Menu: choose wg or subnets)
  wg-vpn config wg                         (Interactive configuration mode)
  wg-vpn config wg /etc/wireguard          (Sets directory, prompts for file)
  wg-vpn config wg /etc/wireguard/wg0.conf (Sets directory and file instantly)
  wg-vpn config wg -y                      (Uses \$PWD as the dir, prompts for file)
  wg-vpn config wg --silent                (Uses \$PWD as the dir, no output)

  wg-vpn config subnets                    (Interactive subnets mode)
  wg-vpn config subnets 10.0.0.0/8         (Adds 10.0.0.0/8 to bypass list)
  wg-vpn config subnets 10.0.0.0/8 rm      (Removes 10.0.0.0/8 from bypass list)

  wg-vpn config init                       (Re-run guided setup)
EOF
}

# CONTROLLER LAYER

cmd_config_wg() {
    local target="${1:-}"

    case "$target" in
    -y)
        _set_wg_dir_and_select "$(pwd)"
        return 0
        ;;
    --silent)
        edit_kv "WG_CONFIG_DIR" "$(pwd)" "$CONFIG_FILE"
        return 0
        ;;
    "")
        :
        ;;
    *)
        if [[ -d "$target" ]]; then
            _set_wg_dir_and_select "$(cd "$target" && pwd)"
        elif [[ -f "$target" && "${target##*.}" == "conf" ]]; then
            local dir file
            dir=$(cd "$(dirname "$target")" && pwd)
            file=$(basename "$target")
            edit_kv "WG_CONFIG_DIR" "$dir" "$CONFIG_FILE"
            edit_kv "WG_CONFIG_FILE" "$file" "$CONFIG_FILE"
            info "Config updated -> Dir: $dir | File: $file"
        else
            die "Invalid argument: '$target' must be a directory or .conf file."
        fi
        return 0
        ;;
    esac

    # Interactive handling
    local current_dir current_file
    current_dir=$(get_env_var "WG_CONFIG_DIR" "$CONFIG_FILE")
    current_file=$(get_env_var "WG_CONFIG_FILE" "$CONFIG_FILE")

    echo ""
    info "Current WireGuard Configuration:"
    echo "  Directory : ${current_dir:-[Not set]}"
    echo "  File      : ${current_file:-[Not set]}"
    echo "-------------------------------------------"

    if yes_no "Set the config directory to the current directory ($(pwd))?"; then
        _set_wg_dir_and_select "$(pwd)"
        return 0
    fi

    _cmd_config_wg_menu
}

cmd_config_subnets() {
    local subnet="${1:-}"
    local action="${2:-add}"

    if [[ -n "$subnet" ]]; then
        if [[ "${action,,}" == "rm" || "${action,,}" == "deny" ]]; then
            _edit_list_file "rm" "$subnet" "$SUBNETS_FILE"
            info "Removed '$subnet' from allowed subnets (if it existed)."
        else
            _edit_list_file "add" "$subnet" "$SUBNETS_FILE"
            info "Added '$subnet' to allowed subnets."
        fi
        return 0
    fi

    while true; do
        local subnets=()
        get_list_from_list_file "$SUBNETS_FILE" "subnets"

        echo ""
        info "Allowed Subnets (Bypassing VPN Kill-Switch):"
        if [[ ${#subnets[@]} -eq 0 ]]; then
            echo "  [No subnets configured]"
        else
            local i=1
            for sub in "${subnets[@]}"; do
                printf " %2d. %s\n" "$i" "$sub"
                ((i++))
            done
        fi
        echo "-------------------------------------------"
        echo "  a. Add a subnet"
        echo "  r. Remove a subnet"
        echo "  x. Exit"
        echo "-------------------------------------------"

        read -r -p "Choice [a/r/x]: " choice || break
        case "${choice,,}" in
        a)
            local new_sub
            read -r -p "Enter CIDR subnet (e.g., 192.168.1.0/24): " new_sub
            if [[ -n "$new_sub" ]]; then
                _edit_list_file "add" "$new_sub" "$SUBNETS_FILE"
                info "Subnet added."
            fi
            ;;
        r)
            if [[ ${#subnets[@]} -eq 0 ]]; then
                echo "No subnets to remove." >&2
                continue
            fi
            local sel
            read -r -p "Select number to remove [1-${#subnets[@]}]: " sel
            if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#subnets[@]})); then
                local rm_sub="${subnets[$((sel - 1))]}"
                _edit_list_file "rm" "$rm_sub" "$SUBNETS_FILE"
                info "Removed '$rm_sub'."
            else
                echo "Invalid selection." >&2
            fi
            ;;
        x) return 0 ;;
        *) echo "Invalid choice." >&2 ;;
        esac
    done
}

cmd_config_init() {
    init_config
    info "Configuration base files initialized at $CONFIG_DIR"
    info "You can now edit $CONFIG_FILE and $SUBNETS_FILE before connecting to skip interactive setup."
}

# Entrypoint router for 'wg-vpn config'
cmd_config() {
    # Lock exclusively to prevent mutating config while VPN starts
    acquire_lock exclusive
    _ensure_config_files

    local subcmd="${1:-}"
    shift || true

    case "${subcmd,,}" in
    wg) cmd_config_wg "$@" ;;
    subnets) cmd_config_subnets "$@" ;;
    init) cmd_config_init ;;
    "") _cmd_config_menu ;;
    -h | --help | help) usage_config ;;
    *)
        usage_config >&2
        exit 1
        ;;
    esac
}
