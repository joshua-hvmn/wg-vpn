#!/usr/bin/env bash
# shellcheck shell=bash
#
# Best effort recording and restoring of UFW rules just in case.
#
# No guarantee, hence lab_require_consent()

## Record and restore UFW snapshot
firewall_snapshot_dir() {
    printf '%s\n' "$BATS_FILE_TMPDIR/ufw-snapshot"
}

firewall_snapshot() {
    local dir
    dir="$(firewall_snapshot_dir)"
    mkdir -p "$dir"

    cp -a /etc/ufw "$dir/etc-ufw"
    cp -a /etc/default/ufw "$dir/default-ufw"
    if ufw status 2>/dev/null | grep -q '^Status: active'; then
        printf 'active\n' >"$dir/state"
    else
        printf 'inactive\n' >"$dir/state"
    fi
}

firewall_restore() {
    local dir
    dir="$(firewall_snapshot_dir)"
    [[ -d "$dir" ]] || return 0

    ufw --force disable >/dev/null 2>&1 || true
    rm -rf /etc/ufw
    cp -a "$dir/etc-ufw" /etc/ufw
    cp -a "$dir/default-ufw" /etc/default/ufw

    if [[ "$(cat "$dir/state")" == "active" ]]; then
        ufw --force enable >/dev/null 2>&1 ||
            printf 'WARNING: could not re-enable ufw; check it manually\n' >&2
    fi
}

firewall_enable_ipv6() {
    if grep -q '^IPV6=' /etc/default/ufw; then
        sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
    else
        printf 'IPV6=yes\n' >>/etc/default/ufw
    fi
}

firewall_outgoing_policy() {
    local policy
    policy="$(LC_ALL=C ufw status verbose 2>/dev/null |
        sed -n 's/^Default:.*, \([a-z]*\) (outgoing).*/\1/p')"
    printf '%s\n' "${policy:-inactive}"
}

## Set baseline to allow
firewall_baseline() {
    firewall_enable_ipv6

    ufw --force reset >/dev/null 2>&1 || true
    ufw --force default deny incoming >/dev/null 2>&1 || true
    ufw --force default allow outgoing >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true

    ufw status 2>&1 | grep -q '^Status: active' || {
        printf 'firewall: ufw refused to start, so nothing below would mean anything.\n' >&2
        printf 'firewall: ufw enable said:\n%s\n' "$(ufw --force enable 2>&1)" >&2
        printf 'firewall: in a container this is usually /proc/sys being read-only;\n' >&2
        printf 'firewall: see test/integration/Dockerfile.\n' >&2
        return 1
    }

    [[ "$(firewall_outgoing_policy)" == "allow" ]] || {
        printf 'firewall: expected a permissive baseline, got: %s\n' "$(ufw status verbose)" >&2
        return 1
    }
}
