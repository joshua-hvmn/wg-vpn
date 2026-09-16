#!/usr/bin/env bash
# shellcheck shell=bash
#
# lab.bash — the network the kill-switch is measured against.
#
# Three links between the host (where wg-vpn and ufw run for real) and one
# isolated network namespace (where every peer the host is allowed — or
# forbidden — to reach lives):
#
#   host / root netns                     netns: wgvpn-lab
#   ----------------------------------    --------------------------------------
#   wgt-ext  198.51.100.1/24  ------->    wgt-ext-far  198.51.100.2  fake endpoint
#            2001:db8:1::1/64                          198.51.100.3  decoy (v4)
#                                                      2001:db8:1::3 decoy (v6)
#
#   wgt-lan  203.0.113.1/24   ------->    wgt-lan-far  203.0.113.2   allowed subnet
#            2001:db8:3::1/64                          2001:db8:3::2 same subnet, v6
#
#   wgt-und  198.18.0.1/24    ------->    wgt-und-far  198.18.0.2    tunnel underlay
#   wgt-wg0  192.0.2.1/32     ==tunnel=>  wgt-wg1      192.0.2.2/32  tunnel target
#
# Every address comes from a range reserved for documentation or benchmarking
# (RFC 5737, RFC 3849, RFC 2544), so the lab cannot be mistaken for — or
# collide with — a real network. Every interface is prefixed "wgt-" so
# cleanup can be exhaustive without touching anything else.
#
# TUNNEL DEVICE
#   If wireguard-tools and the `wireguard` link type are available, the
#   underlay carries a genuine WireGuard tunnel and `ufw allow out on
#   <iface>` is therefore evaluated against a real wireguard netdev. The
#   fake wg-vpn config then points at the *underlay* endpoint, so the tool's
#   own endpoint rule is what permits the handshake — exactly as in
#   production.
#
#   If they are not available, wgt-und plays the tunnel itself and the suite
#   says so out loud. That is reduced coverage on one point, not a silent
#   downgrade.

LAB_NS="wgvpn-lab"
LAB_LINKS=(wgt-ext wgt-lan wgt-und wgt-wg0)

# Service port used by every TCP echo listener in this lab
LAB_PORT=8080
LAB_DNS_PORT=53

# shellcheck disable=SC2034
LAB_MCAST_GROUP="224.0.0.251"
# shellcheck disable=SC2034
LAB_MCAST_PORT=5353

lab_die() {
    printf 'lab: %s\n' "$@" >&2
    return 1
}

lab_ns() {
    ip netns exec "$LAB_NS" "$@"
}

# Must derive in a function, bats runs steps in different shells, so variables/data must be stored
lab_rundir() {
    printf '%s\n' "$BATS_FILE_TMPDIR/lab"
}

# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------
lab_write_env() {
    cat >"$BATS_FILE_TMPDIR/lab.env" <<EOF
LAB_RUNDIR="$LAB_RUNDIR"
LAB_PROBE="$LAB_PROBE"
LAB_HAVE_WIREGUARD="$LAB_HAVE_WIREGUARD"
LAB_TUN_IFACE="$LAB_TUN_IFACE"
LAB_TUN_TARGET="$LAB_TUN_TARGET"
LAB_EP_IP="$LAB_EP_IP"
LAB_EP_PORT="$LAB_EP_PORT"
LAB_EP_CLOSED_PORT="$LAB_EP_CLOSED_PORT"
LAB_WG_PEER_PUB="$LAB_WG_PEER_PUB"
EOF
}

lab_load() {
    # shellcheck source=/dev/null
    source "$BATS_FILE_TMPDIR/lab.env"
}

# --------------------------------------------------------------------------
# Lab manipulation from test
# --------------------------------------------------------------------------
## Simulate the tunnel dying underneath the kill-switch.
lab_tunnel_down() {
    ip link set "$LAB_TUN_IFACE" down
}

lab_tunnel_up() {
    ip link set "$LAB_TUN_IFACE" up
    ip route replace "$LAB_TUN_TARGET/32" dev "$LAB_TUN_IFACE"
}

lab_tunnel_is_up() {
    [[ -n "${LAB_TUN_IFACE:-}" ]] || return 1
    ip link show "$LAB_TUN_IFACE" 2>/dev/null | head -1 | grep -q '[<,]UP[,>]'
}

lab_ensure_tunnel_up() {
    [[ -n "${LAB_TUN_IFACE:-}" ]] || return 1
    ip link show "$LAB_TUN_IFACE" >/dev/null 2>&1 || return 0
    lab_tunnel_is_up && return 0

    lab_tunnel_up || {
        printf 'lab: could not bring %s back up after the test\n' "$LAB_TUN_IFACE" >&2
        return 1
    }
}

## Force the next tunnel packet to require a fresh WireGuard handshake.
#  Without this, a session negotiated before the kill-switch went up could
#  carry the "traffic still flows through the tunnel" assertion, and the
#  endpoint rule would never actually be exercised under enforcement.
lab_reset_tunnel_session() {
    [[ "$LAB_HAVE_WIREGUARD" -eq 1 ]] || return 0
    wg set "$LAB_TUN_IFACE" peer "$LAB_WG_PEER_PUB" remove
    wg set "$LAB_TUN_IFACE" peer "$LAB_WG_PEER_PUB" \
        allowed-ips "$LAB_TUN_TARGET/32" endpoint "$LAB_EP_IP:$LAB_EP_PORT"
}

lab_handshake_count() {
    [[ "$LAB_HAVE_WIREGUARD" -eq 1 ]] || return 0
    wg show "$LAB_TUN_IFACE" latest-handshakes | awk '{print $2}'
}

## Block until a file shows up, or explain what never happened.
lab_wait_for_file() {
    local path="$1" what="${2:-$1}" deadline=$((SECONDS + 15))
    until [[ -f "$path" ]]; do
        ((SECONDS < deadline)) || {
            printf 'lab: timed out waiting for %s\n' "$what" >&2
            return 1
        }
        sleep 0.05
    done
}

# --------------------------------------------------------------------------
# Preconditions
# --------------------------------------------------------------------------

# Skip lab on workstation; fail if in testable environment but missing precondition
lab_unavailable() {
    if [[ -n "${CI:-}" || -f /.dockerenv ]]; then
        lab_die "$1 - but this is CI/test container, where that is not optional"
    fi
    skip "$1"
}

lab_require_root() {
    [[ "$(id -u)" -eq 0 ]] || lab_unavailable "requires root"
}

lab_require_tools() {
    local tool
    for tool in ip ufw python3; do
        command -v "$tool" >/dev/null 2>&1 || lab_unavailable "$tool is not installed"
    done
}

# Strictly require consent outside of CI/container due to destructive UFW resets
lab_require_consent() {
    [[ -f /.dockerenv ]] && return 0
    [[ -n "${CI:-}" ]] && return 0
    [[ -n "${WGVPN_ALLOW_UFW_RESET:-}" ]] && return 0

    printf '%s\n' \
        "REFUSING TO RUN: this suite resets this machine's ufw configuration." \
        "Run it in the disposable container instead:  make test-integration" \
        "Or, if you really mean it:  WGVPN_ALLOW_UFW_RESET=1 make test-integration-host" >&2
    return 1
}

# --------------------------------------------------------------------------
# Build / destroy
# --------------------------------------------------------------------------
lab_add_link() {
    local name="$1" v4="$2" v6="${3:-}"

    ip link add "$name" type veth peer name "$name-far"
    ip link set "$name-far" netns "$LAB_NS"
    ip addr add "$v4" dev "$name"
    [[ -n "$v6" ]] && ip -6 addr add "$v6" dev "$name" nodad
    ip link set "$name" up
    lab_ns ip link set "$name-far" up
}

## Start a background listener and remember it for teardown.
lab_spawn() {
    local name="$1"
    shift
    rm -f "$LAB_RUNDIR/ready.$name"
    "$@" --ready "$LAB_RUNDIR/ready.$name" >"$LAB_RUNDIR/log.$name" 2>&1 &
    printf '%s\n' "$!" >>"$LAB_RUNDIR/pids"
    LAB_PENDING+=("$name")
}

## Wait until every listener reports itself bound.
lab_wait_ready() {
    local name deadline=$((SECONDS + 15))
    for name in "${LAB_PENDING[@]}"; do
        until [[ -f "$LAB_RUNDIR/ready.$name" ]]; do
            ((SECONDS < deadline)) ||
                lab_die "listener '$name' never came up:" "$(cat "$LAB_RUNDIR/log.$name" 2>/dev/null)"
            sleep 0.05
        done
    done
    LAB_PENDING=()
}

lab_serve() {
    local kind="$1" address="$2" port="$3" name="$4"
    lab_spawn "$name" ip netns exec "$LAB_NS" \
        python3 "$LAB_PROBE" "serve-$kind" "$address" "$port"
}

lab_setup_tunnel() {
    LAB_TUN_TARGET="192.0.2.2"

    if command -v wg >/dev/null && ip link add dev wgt-wg0 type wireguard 2>/dev/null; then
        LAB_HAVE_WIREGUARD=1
        LAB_TUN_IFACE="wgt-wg0"
        LAB_EP_IP="198.18.0.2" # Tunnel's real underlay endpoint
        LAB_EP_PORT=51821
        LAB_EP_CLOSED_PORT=51822

        lab_add_link wgt-und 198.18.0.1/24
        lab_ns ip addr add 198.18.0.2/24 dev wgt-und-far

        local host_key peer_key
        host_key="$(wg genkey)"
        peer_key="$(wg genkey)"
        LAB_WG_HOST_PUB="$(printf '%s' "$host_key" | wg pubkey)"
        LAB_WG_PEER_PUB="$(printf '%s' "$peer_key" | wg pubkey)"

        ip addr add 192.0.2.1/32 dev wgt-wg0
        wg set wgt-wg0 private-key <(printf '%s' "$host_key") listen-port 51820 \
            peer "$LAB_WG_PEER_PUB" allowed-ips "$LAB_TUN_TARGET/32" \
            endpoint "$LAB_EP_IP:$LAB_EP_PORT"
        ip link set wgt-wg0 up
        ip route replace "$LAB_TUN_TARGET/32" dev wgt-wg0

        lab_ns ip link add dev wgt-wg1 type wireguard
        lab_ns ip addr add "$LAB_TUN_TARGET/32" dev wgt-wg1
        lab_ns wg set wgt-wg1 private-key <(printf '%s' "$peer_key") listen-port "$LAB_EP_PORT" \
            peer "$LAB_WG_HOST_PUB" allowed-ips 192.0.2.1/32 \
            endpoint 198.18.0.1:51820
        lab_ns ip link set wgt-wg1 up
        lab_ns ip route replace 192.0.2.1/32 dev wgt-wg1
    else
        LAB_HAVE_WIREGUARD=0
        LAB_TUN_IFACE="wgt-und"
        LAB_EP_IP="198.51.100.2" # Fake endpoint on fake uplink
        LAB_EP_PORT=51820
        LAB_EP_CLOSED_PORT=51821
        LAB_WG_PEER_PUB=""

        printf 'lab: wireguard-tools or the wireguard link type is unavailable; ' >&2
        printf 'the tunnel interface is a plain veth for this run\n' >&2

        lab_add_link wgt-und 192.0.2.1/24
        lab_ns ip addr add "$LAB_TUN_TARGET/24" dev wgt-und-far
    fi
}

lab_setup_services() {
    # Peers to allow through
    lab_serve tcp "$LAB_TUN_TARGET" "$LAB_PORT" tunnel
    lab_serve tcp 203.0.113.2 "$LAB_PORT" lan-v4
    [[ "$LAB_HAVE_WIREGUARD" -eq 1 ]] || lab_serve udp "$LAB_EP_IP" "$LAB_EP_PORT" endpoint

    # Peers to block
    lab_serve udp "$LAB_EP_IP" "$LAB_EP_CLOSED_PORT" endpoint-other-port
    lab_serve tcp 198.51.100.3 "$LAB_PORT" decoy-v4
    lab_serve tcp 2001:db8:1::3 "$LAB_PORT" decoy-v6
    lab_serve udp 198.51.100.3 "$LAB_DNS_PORT" decoy-dns
    lab_serve tcp 2001:db8:3::2 "$LAB_PORT" lan-v6

    lab_wait_ready
}

lab_teardown() {
    local rundir
    rundir="$(lab_rundir)"

    # Kill listeners and then delete
    if [[ -f "$rundir/pids" ]]; then
        local pid
        while read -r pid; do
            kill -0 "$pid" 2>/dev/null || continue
            kill "$pid" 2>/dev/null ||
                printf 'lab: WARNING could not kill listener pid %s\n' "$pid" >&2
        done <"$rundir/pids"
        : >"$rundir/pids"
    fi

    if ip netns list 2>/dev/null | grep -qw "$LAB_NS"; then
        ip netns del "$LAB_NS" 2>/dev/null ||
            printf 'lab: WARNING could not delete namespace %s\n' "$LAB_NS" >&2
    fi

    local link
    for link in "${LAB_LINKS[@]}"; do
        ip link show "$link" >/dev/null 2>&1 || continue
        ip link del "$link" 2>/dev/null ||
            printf 'lab: WARNING could not delete link %s\n' "$link" >&2
    done
}

lab_setup() {
    LAB_RUNDIR="$(lab_rundir)"
    LAB_PROBE="$BATS_TEST_DIRNAME/support/netlab.py"
    mkdir -p "$LAB_RUNDIR"
    : >"$LAB_RUNDIR/pids"
    LAB_PENDING=()

    lab_teardown

    ip netns add "$LAB_NS" || lab_die "could not create namespace $LAB_NS"
    lab_ns ip link set lo up

    lab_add_link wgt-ext 198.51.100.1/24 2001:db8:1::1/64
    lab_ns ip addr add 198.51.100.2/24 dev wgt-ext-far
    lab_ns ip addr add 198.51.100.3/24 dev wgt-ext-far
    lab_ns ip -6 addr add 2001:db8:1::3/64 dev wgt-ext-far nodad

    lab_add_link wgt-lan 203.0.113.1/24 2001:db8:3::1/64
    lab_ns ip addr add 203.0.113.2/24 dev wgt-lan-far
    lab_ns ip -6 addr add 2001:db8:3::2/64 dev wgt-lan-far nodad

    lab_setup_tunnel
    lab_setup_services
    lab_write_env
}
