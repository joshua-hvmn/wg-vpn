#!/usr/bin/env bash
#
# Run the kill-switch suite inside a disposable container.
#
# The container has its own network namespace, so the ufw resets, the veth
# pairs and the deny-by-default policy inside it cannot touch this machine's
# firewall or interfaces. That isolation is the entire safety story of this
# suite: never add --network host.
#
# Usage:
#   test/integration/run.sh
#   test/integration/run.sh --filter 'tunnel dying'
#
# For the higher-fidelity run, load the WireGuard module first
# (`sudo modprobe wireguard`) so the suite can build a real tunnel instead of
# a stand-in veth. It works either way and tells you which one it used.

set -euo pipefail
cd "$(dirname "$0")/../.."

readonly IMAGE="wg-vpn-integration-test"
readonly SUITE="test/integration/killswitch.bats"

if ! command -v docker >/dev/null 2>&1; then
    cat >&2 <<'EOF'
error: docker is required to sandbox this suite.

To run it directly against this machine's firewall instead — which resets
ufw and does not fully restore it — use:

    make test-integration-host
EOF
    exit 1
fi

printf ' %-8s %s\n' "BUILD" "$IMAGE"
docker build --quiet --tag "$IMAGE" --file test/integration/Dockerfile . >/dev/null

printf '%-8s %s\n' "RUN" "$SUITE"
exec docker run --rm \
    --network none \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --cap-add=SYS_ADMIN \
    --security-opt apparmor=unconfined \
    --security-opt seccomp=unconfined \
    --volume "$PWD:/repo:ro" \
    "$IMAGE" "$@" "$SUITE"
