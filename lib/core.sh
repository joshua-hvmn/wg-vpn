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

## Acquire lock on state
#  USAGE: acquire_lock [shared|exclusive]
#  - shared: for read-only ops (status), multiple readers but blocked if writer lock
#  - exclusive: state mutation (VPN up/down, rule changes)
#  Safe to call more than once in one process
acquire_lock() {
    local mode="${1:-exclusive}"

    [[ "$LOCK_ACQUIRED" -eq 1 ]] && return 0

    mkdir -p "$STATE_DIR"
    exec {LOCK_FD}>"$LOCK_FILE"

    local flag="-x"
    [[ "$mode" == "shared" ]] && flag="-s"

    flock -w 5 "$flag" "$LOCK_FD" || die "Another instance of wg-vpn is currently running. Please wait."
    LOCK_ACQUIRED=1
}

rollback_on_error() {
    info "An error occurred while starting the VPN, or the script was interrupted. Rolling back..."

    # 1. Restore UFW default outgoing policy
    if [[ -n "${PREV_UFW_POLICY:-}" ]]; then
        sudo ufw default "$PREV_UFW_POLICY" outgoing >/dev/null 2>&1
    else
        sudo ufw default allow outgoing >/dev/null 2>&1
    fi

    # 2. Delete endpoint rule
    if [[ -n "${ENDPOINT_IP:-}" && -n "${ENDPOINT_PORT:-}" ]]; then
        sudo ufw delete allow out to "$ENDPOINT_IP" port "$ENDPOINT_PORT" proto udp >/dev/null 2>&1 || true
    fi

    # 3. Delete interface rule
    if [[ -n "${WG_IFACE:-}" ]]; then
        sudo ufw delete allow out on "$WG_IFACE" >/dev/null 2>&1 || true
    fi

    # 4. Delete allowed subnets
    if [[ "${#ALLOWED_SUBNETS[@]}" -gt 0 ]]; then
        for subnet in "${ALLOWED_SUBNETS[@]}"; do
            sudo ufw delete allow out to "$subnet" >/dev/null 2>&1 || true
        done
    fi

    # 5. Restore IPv6 state
    if command -v disable_ipv6 >/dev/null 2>&1; then
        if [[ -n "${PREV_IPV6_STATE:-}" ]]; then
            disable_ipv6 "$PREV_IPV6_STATE"
        else
            disable_ipv6 0
        fi
    fi

    # 6. Ensure NM connection is down
    if [[ -n "${CONNECTION_NAME:-}" ]]; then
        if [[ "${CONNECTION_IMPORTED:-0}" -eq 1 ]]; then
            info "Removing newly imported connection: $CONNECTION_NAME"
            nmcli connection delete "$CONNECTION_NAME" >/dev/null 2>&1 || true
        else
            nmcli connection down "$CONNECTION_NAME" >/dev/null 2>&1 || true
        fi
    fi

    sudo ufw reload >/dev/null 2>&1
    rm -f "$STATE_FILE"
    info "Rollback complete. Network restored to previous state."
}

## Get indexed array from map file
# USAGE: get_list_from_map_file <KEY> <FILE> <TARGET_ARRAY_NAME>
# - Gather all values for given a key in a given map file into a global array
get_list_from_map_file() {
    local key="$1"
    local file="$2"
    local target_name="$3"

    declare -g -a "$target_name"
    local -n _map_target_ref="$target_name"
    _map_target_ref=()

    [[ -f "$file" ]] || return 1

    local k v
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        # Strip key whitespaces
        k="${k// /}"

        # Skip comments, empty lines, non-matches
        [[ -z "$k" || "$k" == \#* || "$k" != "$key" ]] && continue

        # Strip quotes
        v="${v#\"}"
        v="${v%\"}"
        v="${v#\'}"
        v="${v%\'}"

        # Strip value whitespaces
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"

        [[ -n "$v" ]] && _map_target_ref+=("$v")
    done <"$file"
}

## Get Indexed Array from list file
#  USAGE: get_list_from_list_file <FILE> <TARGET_ARRAY_NAME>
#  - Use this function to build a list from a list file
#  - Clears and overwrites the global array that is targeted
#  - Strips comments and whitespaces
get_list_from_list_file() {
    local file="$1"
    local target_name="$2"

    declare -g -a "$target_name"
    local -n _list_target_ref="$target_name"
    _list_target_ref=()

    [[ -f "$file" ]] || return 1

    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}" # Strip comments
        line="${line// /}" # Strip whitespaces
        [[ -n "$line" ]] && _list_target_ref+=("$line")
    done <"$file"
}

## [Y/n]
#  - Move the '' to the no section to change to default no.
yes_no() {
    local msg="${1:-''}"
    local response
    while true; do
        read -r -p "$msg [Y/n]: " response >&2
        case "$response" in
        n | N | [nN]o | [nN]O | [nN][oO])
            return 1
            ;;
        '' | [yY] | [yY]es | [yY][eE][sS])
            return 0
            ;;
        *)
            info "Invalid response: $response"
            ;;
        esac
    done
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
        tmp_file=$(mktemp "$dir/.$base.XXXXXX") || {
            umask "$umask_old"
            return 1
        }
    else
        # Bash fallback
        tmp_file="$dir/.$base.$$.$RANDOM"
        set -C
        : >"$tmp_file" 2>/dev/null || {
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
        die "Setup aborted. wg-vpn cannot proceed without required variables."
    fi

}

load_env() {
    init_config

    [[ -f "$CONFIG_FILE" ]] || die "missing $CONFIG_FILE"
    for var_name in "${!ENV_VARS[@]}"; do
        local val
        val=$(get_env_var "$var_name" "$CONFIG_FILE")
        declare -g -x "$var_name=$val"
    done

    if [[ ! -f "$SUBNETS_FILE" ]]; then
        info "Generating default private subnets list..."
        mkdir -p "$CONFIG_DIR"
        cat <<EOF >"$SUBNETS_FILE"
# Local network subnets to bypass the VPN kill-switch
# These are standard CIDR local ranges.
# Add or remove allowed IPs below as needed.
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
EOF
    fi

    [[ -n "${WG_CONFIG_DIR:-}" ]] || die "WG_CONFIG_DIR not set in $CONFIG_FILE"
    [[ -n "${WG_CONFIG_FILE:-}" ]] || die "WG_CONFIG_FILE not set in $CONFIG_FILE"

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

    # Strip inline comments
    line="${line%%#*}"
    # Strip key and whitespace
    line="${line#*=}"
    line="${line// /}"

    ENDPOINT_IP="${line%:*}"
    ENDPOINT_IP="${ENDPOINT_IP//[\[\]]/}"
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
    PREV_UFW_POLICY=$(LANG=C sudo ufw status verbose | grep -o '[a-z]* (outgoing)' | awk '{print $1}' || true)
    [[ -z "$PREV_UFW_POLICY" ]] && PREV_UFW_POLICY="allow"

    PREV_IPV6_STATE=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")

    export PREV_UFW_POLICY PREV_IPV6_STATE
}

write_state_file() {
    info "Gathering active interface data..."
    local tries=0
    while [[ $tries -lt 15 ]]; do
        WG_IFACE=$(nmcli -g GENERAL.DEVICES connection show "$CONNECTION_NAME" 2>/dev/null | head -n1 || true)
        [[ -n "$WG_IFACE" ]] && break
        sleep 0.3
        ((tries++)) || true
    done
    [[ -n "$WG_IFACE" ]] || die "could not determine interface for $CONNECTION_NAME"

    # Save state
    mkdir -p "${STATE_FILE%/*}"
    local tmp
    tmp=$(make_temp "$STATE_FILE") || die "cannot create temp state file"

    {
        cat <<EOF
ENDPOINT_IP="$ENDPOINT_IP"
ENDPOINT_PORT="$ENDPOINT_PORT"
CONNECTION_NAME="$CONNECTION_NAME"
WG_IFACE="$WG_IFACE"
PREV_UFW_POLICY="$PREV_UFW_POLICY"
PREV_IPV6_STATE="$PREV_IPV6_STATE"
EOF
        for subnet in "${ALLOWED_SUBNETS[@]}"; do
            printf 'ALLOWED_SUBNET="%s"\n' "$subnet"
        done
    } >"$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
    export WG_IFACE
}

disable_ipv6() {
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6="$1" >/dev/null
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6="$1" >/dev/null
}
