if [[ "$ENTRYPOINT_LOADED" != "true" ]]; then
    echo "Error: This script is a component of wg-vpn and cannot be run directly."
    echo "Run 'wg-vpn [cmd]'"
    exit 1
fi

# Helpers
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}
info() {
    printf '→ %s\n' "$*"
}

## Get environment variable value from file
#  - USAGE: 'get_env_var <KEY> <FILE>'
#  Checks current shell for the variable, then searches the file
#  Returns the value or 'error'
get_env_var() {
    local key="$1"
    local file="$2"
    local default="${3:-}"

    # Prefer already-exported value
    if [[ -n "${!key:-}" ]]; then
        printf '%s' "${!key}"
        return 0
    fi

    local file_val
    file_val=$(sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1)
    file_val="${file_val%\"}" # Strip trailing quote
    file_val="${file_val#\"}" # Strip leading quote
    if [[ -n "$file_val" ]]; then
        printf '%s' "$file_val"
    else
        printf '%s' "$default"
    fi
}

make_temp() {
    [[ $# -eq 1 ]] || return 2
    local target="$1"
    local dir="${target%/*}"
    local base="${target##*/}"

    [[ -d "$dir" && -w "$dir" ]] || return 1

    local umask_old
    umask_old=$(umask)
    umask 077

    local tmp_file
    if command -v mktemp >/dev/null 2>&1; then
        tmp_file=(mktemp "$dir/.$base.XXXXXX") || {
            umask "$umask_old"
            return 1
        }
    else
        # Bash fallback
        tmp_file="$dir/.$base.$$.$RANDOM"
        set -C
        >"$tmp_file" 2>/dev/null || {
            umask "$umask_old"
            return 1
        }
        set +C
        chmod 600 "$tmp_file"
    fi

    umask "$umask_old"
    printf '%s\n' "$tmp_file"
}

edit_kv() {
    [[ $# -ge 2 ]] || return 2

    local rm_mode=0 key value target
    if [[ "$1" == "rm" ]]; then
        rm_mode=1
        key="$2"
        target="$3"
    else
        key="$1"
        value="$2"
        target="$3"
    fi

    [[ -n "$target" ]] || return 1
    local dir="${target%/*}"
    [[ -d "$dir" && -w "$dir" ]] || return 1
    [[ -f "$target" ]] || touch -- "$target" 2>/dev/null || return 1

    # Escape key for sed
    local ekey
    ekey=$(printf '%s' "$key" | sed 's/\\/\\\\/g; s/[][\/.^$*]/\\&/g')

    local tmp
    tmp=$(make_temp "$target") || return 1

    sed "/^${ekey}=/d" "$target" >"$tmp" || {
        rm -f -- "$tmp"
        return 1
    }

    if [[ "$rm_mode" -eq 0 ]]; then
        # check for newline
        [[ -s "$tmp" && "$(tail -c 1 "$tmp" 2>/dev/null)" != $'\n' ]] && printf '\n' >>"$tmp"
        printf '%s=%s\n' "$key" "$value" >>"$tmp" || {
            rm -f -- "$tmp"
            return 1
        }
    fi

    local perms
    perms=$(stat -c %a "$target" 2>/dev/null || printf '600')
    chmod "$perms" "$tmp"
    mv -f -- "$tmp" "$target" || {
        rm -f -- "$tmp"
        return 1
    }
}

init_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        info "First run detected. Initializing configuration."
        mkdir -p "${CONFIG_FILE%/*}"

        local wg_dir wg_file
        read -r -p "Enter Wireguard config directory (e.g., /etc/wireguard/): " wg_dir
        read -r -p "Enter default config file (e.g., us1.conf): " wg_file

        edit_kv "$WG_CONFIG_DIR" "$wg_dir" "$CONFIG_FILE"
        edit_kv "$WG_CONFIG_FILE" "$wg_file" "$CONFIG_FILE"

        info "Configuration saved to $CONFIG_FILE"
    fi
}

load_env() {
    init_config

    [[ -f "$CONFIG_FILE" ]] || die "missing $CONFIG_FILE"
    for var_name in "${ENV_VARS[@]}"; do
        local val
        val=$(get_env_var "$var_name" "$CONFIG_FILE")
        declare -g -x "$var_name=$val"
    done

    [[ -n "${WG_CONFIG_DIR:-}" ]] || die "WG_CONFIG_DIR not set in .env"
    [[ -n "${WG_CONFIG_FILE:-}" ]] || die "WG_CONFIG_FILE not set in .env"

    CONFIG_PATH="${WG_CONFIG_DIR%/}/${WG_CONFIG_FILE}"
    [[ -f "$CONFIG_PATH" ]] || die "config file not found: $CONFIG_PATH"

    # Connection name = filename without .conf (nmcli default behaviour)
    CONNECTION_NAME="${WG_CONFIG_FILE%.conf}"
    export CONFIG_PATH CONNECTION_NAME
}

load_state_file() {
    [[ -f "$STATE_FILE" ]] || die "State file missing ($STATE_FILE)."

    local line key val
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
        # strip whitespaces from key
        key="${key// /}"

        [[ -z "$key" || "$key" == \#* ]] && continue

        val="${val#\"}"
        val="${val%\"}"
        val="${val#\'}"
        val="${val%\'}"

        declare -g -x "$key=$val"
    done <"$STATE_FILE"
}

parse_endpoint() {
    local line
    line=$(grep -E '^\s*Endpoint\s*=' "$CONFIG_PATH" | head -1) ||
        die "no Endpoint= line found in $CONFIG_PATH"

    # Strip key and whitespace
    line="${line#*=}"
    line="${line// /}"

    ENDPOINT_IP="${line%:*}"
    ENDPOINT_PORT="${line##*:}"

    [[ -n "$ENDPOINT_IP" && -n "$ENDPOINT_PORT" ]] ||
        die "failed to parse Endpoint from $CONFIG_PATH"

    export ENDPOINT_IP ENDPOINT_PORT
}

check_deps() {
    for dep in "${DEPENDENCIES[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || die "Missing dependency: $dep"
    done
}

capture_pre_vpn_state() {
    info "Gathering pre-VPN state data..."

    # Get current UFW outgoing policy to restore later
    PREV_UFW_POLICY=$(sudo ufw status verbose | grep -o '[a-z]* (outgoing)' | awk '{print $1}')
    [[ -z "$PREV_UFW_POLICY" ]] && PREV_UFW_POLICY="allow"

    export PREV_UFW_POLICY
}

write_state_file() {
    info "Gathering active interface data..."

    WG_IFACE=$(nmcli -g GENERAL.DEVICES connection show "$CONNECTION_NAME" | head -n1)
    [[ -z "$WG_IFACE" ]] && WG_IFACE="$CONNECTION_NAME" # Fallback just in case

    # Save state
    mkdir -p "${STATE_FILE%/*}"
    cat <<EOF >"$STATE_FILE"
ENDPOINT_IP="$ENDPOINT_IP"
ENDPOINT_PORT="$ENDPOINT_PORT"
CONNECTION_NAME="$CONNECTION_NAME"
WG_IFACE="$WG_IFACE"
PREV_UFW_POLICY="$PREV_UFW_POLICY"
EOF
    chmod 600 "$STATE_FILE"

    export WG_IFACE
}

disable_ipv6() {
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=$1 >/dev/null
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6=$1 >/dev/null
}
