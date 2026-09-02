# wg-vpn

A robust, Bash-based WireGuard client manager with automatic UFW kill-switch support.

**wg-vpn** simplifies managing WireGuard connections on Linux by handling configuration imports via `nmcli`, applying a dynamic firewall kill-switch using `ufw`, and maintaining state to ensure safe rollback if the connection fails.

## Features

- **Zero Compilation**: Pure Bash script
- **Automatic Firewall Management**:
    - Applies a kill-switch to prevent outbound traffic from circumventing the VPN tunnel.
    - Whitelists VPN endpoints (parsed from config) and local subnets automatically.
    - Restores previous firewall policies on disconnect - useful for gamers (the entire reason I made a toggle script to begin with)
- **State Awareness**: Tracks active interfaces and UFW rules to ensure clean disconnects, even after crashes and reboots.
- **Rollback Protection**: Protected by `traps`, if any step of the startup process fails, a thorough rollback function is triggered.
- **XDG Compliant**: Stores configuration in `$XDG_CONFIG_HOME/wg-vpn` and state in `$XDG_STATE_HOME/wg-vpn`

## Requirements

- **Bash 4.3+**
- **Linux Kernel** with WireGuard support
- **Dependencies**: `nmcli`, `ufw`, `sudo`, `iproute2` (`ip`), `util-linux` (`flock`)

## Installation

### From Source:

Download the latest release tarball, signature, and checksum file from the [Releases page](https://github.com/joshua-hvmn/wg-vpn/releases).

**1. Download the artifacts** (Replace `v0.1.1` with target version):
```bash
VERSION="v0.1.1"
curl -sLO "https://github.com/joshua-hvmn/wg-vpn/releases/download/${VERSION}/wg-vpn-${VERSION}.tar.gz"
curl -sLO "https://github.com/joshua-hvmn/wg-vpn/releases/download/${VERSION}/wg-vpn-${VERSION}.tar.gz.sig"
curl -sLO "https://github.com/joshua-hvmn/wg-vpn/releases/download/${VERSION}/wg-vpn-${VERSION}.tar.gz.sha256"
```

**2. Verify checksum and signature**:
```bash
# Verify SHA256 checksum
sha256sum -c "wg-vpn-${VERSION}.tar.gz.sha256"

# Verify GPG signature (requires importing the maintainer's public key first)
gpg --verify "wg-vpn-${VERSION}.tar.gz.sig" "wg-vpn-${VERSION}.tar.gz"
```

**3. Extract and install**:
```bash
tar -xzf "wg-vpn-${VERSION}.tar.gz"
cd "wg-vpn-${VERSION}"
make install
```

## Uninstallation

To remove the script and library files, run the following from the extracted source directory (stop wg-vpn first):
```bash
make uninstall
```
*(Note: This leaves your config file in `~/.config/wg-vpn` intact.)*

## Usage
### Initialization

**wg-vpn** generates and validates the config files when run:
```
sudo wg-vpn
```
*Alternatively, run* `sudo wg-vpn init` *to initialize the files without being prompted to enter variables.*

Initialization creates:
- `$XDG_CONFIG_HOME/wg-vpn/wg-vpn.conf`: Main configuration file (requires `WG_CONFIG_DIR` and `WG_CONFIG_FILE`).
- `$XDG_CONFIG_HOME/wg-vpn/subnets.list`: List of local subnets to bypass the kill-switch.

### Commands

| Command | Alias | Description |
| :--- | :--- | :--- |
| `on` / `up` | - | Import/activate WireGuard + enable UFW kill-switch |
| `off` / `down` | - | Deactivate WireGuard + restore outgoing traffic |
| `toggle` | (default) | Switch between on/off automatically |
| `status` | `ps` | Show current VPN and UFW state |
| `help` | `usage` | Show help menu |
| `init` | `--init-config` | Initialize config files so you can edit them before running |

### Examples
- **Toggle VPN on/off**: `sudo wg-vpn`
- **Connect to VPN**: `sudo wg-vpn up`
- **Disconnect**: `sudo wg-vpn down`

## Configuration
The main configuration file is located at `~/.config/wg-vpn/wg-vpn.conf`.

- **`wg-vpn.conf` Format**:
```
# Directory containing your wireguard .conf files
WG_CONFIG_DIR="/etc/wireguard"

# Filename of the config to use (without path)
WG_CONFIG_FILE="my-vpn.conf"
```

- **`subnets.list` Format**:
```
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
# Add your local router here if needed (e.g., 192.168.1.0/24)
```

## How It Works
1. **Import**: Uses `nmcli connection import` to load the WireGuard config into NetworkManager.
2. **Kill-Switch**: Sets UFW allow out on the wireguard interface before setting the default outgoing policy to deny.
3. **Whitelisting**: Adds specific rules for:
    - The VPN Endpoint (before deny out, so nmcli can resolve the IP if necessary).
    - The WG interface itself.
    - Local subnets defined in `subnets.list`.
4. **State File**: Writes active state to `~/.local/state/wg-vpn/wg-vpn.state` to track policiies.
5. **Lock File**: Use a lock file to prevent race conditions and improve idempotency.

## Architecture
```
wg-vpn/
├── wg-vpn          # Main entrypoint
├── lib/
│   ├── core.sh     # Helpers, locking, config parsing
│   ├── routers.sh  # Command routing logic
│   └── commands/
│       ├── misc.sh      # Status, Help, Init
│       └── toggle-vpn.sh # Core On/Off/Toggle logic
└── test/           # BATS unit tests
```

## Contributing
1. Fork this repository.
2. Create a feature branch.
3. Run `make check` to ensure linting and tests pass
4. Submit a Pull Request.

## License: MIT
This software is provided as is without warranty. Use with caution, and verify package signatures. You are free to copy and modify this code.
