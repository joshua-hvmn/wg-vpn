#!/usr/bin/env bash
# Sandboxes the destructive kill-switch test in a disposable container.
# Docker gives it its own network namespace, so ufw inside it never
# touches this host's real firewall - as long as --network host is
# never added below.
set -euo pipefail
cd "$(dirname "$0")/../.."

docker build -t wg-vpn-integration-test -f test/integration/Dockerfile .
docker run --rm \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --cap-add=SYS_ADMIN \
    -v "$PWD:/repo:ro" \
    wg-vpn-integration-test
