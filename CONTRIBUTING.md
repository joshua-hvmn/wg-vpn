# Contributing to wg-vpn

## Development setup

```bash
git clone <repo>
cd wg-vpn
make lint
make test-unit
make test-integration   # requires Docker
```

## Code style

- Bash ≥ 4.3, `set -euo pipefail`
- 4-space indent (`shfmt -i 4`)
- `shellcheck -x -s bash` must be clean
- Prefer small, single-purpose functions
- Never prompt when `NONINTERACTIVE=1` or stdin is not a TTY

## Tests

- Unit tests live in `test/*.bats` and use mocks.
- Integration tests live in `test/integration/` and run against real UFW inside Docker.
- Every “must be blocked” assertion is preceded by a control that proves the probe works when the kill-switch is off.
- A probe exit code of 2 (cannot run) must never be treated as a successful block.

## Pull requests

1. Keep the change focused.
2. Update or add tests for any behavioural change.
3. Run `make check` (or at least `make lint test-unit`).
4. Do not commit real WireGuard private keys or production configs.
