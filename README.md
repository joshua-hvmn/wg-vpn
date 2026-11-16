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
- **Recommended**: `conntrack-tools`, so connections opened before the kill-switch armed are cut instead of living on until they close
- The WireGuard config's `Endpoint` must be an IP address, not a hostname (see [SECURITY.md](SECURITY.md))

## Installation

### From Source:

Download the latest release tarball, signature, and checksum file from the [Releases page](https://github.com/joshua-hvmn/wg-vpn/releases).

**1. Download the artifacts** (Replace `v0.2.0` with target version):

```bash
VERSION="v0.2.0"
curl -sLO "https://github.com/joshua-hvmn/wg-vpn/releases/download/${VERSION}/wg-vpn-${VERSION}.tar.gz"
curl -sLO "https://github.com/joshua-hvmn/wg-vpn/releases/download/${VERSION}/wg-vpn-${VERSION}.tar.gz.sig"
curl -sLO "https://github.com/joshua-hvmn/wg-vpn/releases/download/${VERSION}/wg-vpn-${VERSION}.tar.gz.sha256"
```

**2. Verify checksum and signature**:

```bash
# Verify SHA256 checksum
sha256sum -c "wg-vpn-${VERSION}.tar.gz.sha256"

# Import the signing key (once), then verify the GPG signature
gpg --keyserver keyserver.ubuntu.com --recv-keys 4474376DA30B98D6FC34D217348CC5A7E89CC1CD
gpg --verify "wg-vpn-${VERSION}.tar.gz.sig" "wg-vpn-${VERSION}.tar.gz"
```

[Verifying a release](#verifying-a-release) explains the key.

**3. Extract and install**:

```bash
tar -xzf "wg-vpn-${VERSION}.tar.gz"
cd "wg-vpn-${VERSION}"
sudo make install    # into /usr/local; or for just you: make install prefix="$HOME/.local"
```

The tarball includes the unit tests: `make test-unit` runs them before you install.

### Verifying a release

Every release tarball is signed, and its build provenance is attested by GitHub. A stable
release's `PKGBUILD` is signed with the same key: `gpg --verify PKGBUILD.sig PKGBUILD`.

**Primary key**, the one to trust (confirm it somewhere other than this repository):

```
4474 376D A30B 98D6 FC34  D217 348C C5A7 E89C C1CD
```

**Signing subkey**, used only for this repository's releases:

```
09BF 2195 0E80 C72E 5669  E3BD 4649 5073 FA6E B22F
```

gpg's "using EDDSA key" line names the signing subkey. Unless you've certified the key, gpg also
warns that it isn't certified and prints both fingerprints: "Primary key fingerprint" should match
the primary key above, and "Subkey fingerprint" the signing subkey. Each repository has its own
subkey, so a compromised one can be revoked without affecting the primary key or other projects.

With `gh` logged in, you can check the provenance instead:
`gh attestation verify wg-vpn-vX.Y.Z.tar.gz --repo joshua-hvmn/wg-vpn`.

## Uninstallation

To remove the script and library files, run the following from the extracted source directory (stop wg-vpn first):

```bash
make uninstall
```

_(Note: This leaves your config file in `~/.config/wg-vpn` intact.)_

## Usage

### Initialization

**wg-vpn** generates and validates the config files when run:

```
wg-vpn
```

_Alternatively, run_ `wg-vpn init` _to initialize the files without being prompted to enter variables._

Initialization creates:

- `$XDG_CONFIG_HOME/wg-vpn/wg-vpn.conf`: Main configuration file (requires `WG_CONFIG_DIR` and `WG_CONFIG_FILE`).
- `$XDG_CONFIG_HOME/wg-vpn/subnets.list`: List of local subnets to bypass the kill-switch.

### Commands

| Command        | Alias           | Description                                                             |
| :------------- | :-------------- | :---------------------------------------------------------------------- |
| `on` / `up`    | -               | Import/activate WireGuard + enable UFW kill-switch                      |
| `off` / `down` | -               | Deactivate WireGuard + restore outgoing traffic                         |
| `toggle`       | (default)       | Switch between on/off automatically                                     |
| `status`       | `ps`            | Show current VPN and UFW state                                          |
| `help`         | `usage`         | Show help menu                                                          |
| `init`         | `--init-config` | Initialize config files so you can edit them before running             |
| `config`       | -               | Set the WireGuard config and the allowed subnets (`wg-vpn config help`) |
| `version`      | `-v`            | Print the version                                                       |

### Examples

- **Toggle VPN on/off**: `wg-vpn`
- **Connect to VPN**: `wg-vpn up`
- **Disconnect**: `wg-vpn down`

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
2. **Kill-Switch**: Allows the VPN endpoint out, sets the default outgoing policy to deny, and cuts connections opened before that. Only then is the connection brought up.
3. **Whitelisting**: Once the tunnel is up, adds rules for:
   - The WG interface itself.
   - Local subnets defined in `subnets.list`.
4. **State File**: Writes active state to `~/.local/state/wg-vpn/wg-vpn.state` to track policies.
5. **Lock File**: Use a lock file to prevent race conditions and improve idempotency.

## Architecture

```
wg-vpn/
├── wg-vpn          # Main entrypoint
├── lib/
│   ├── core.sh     # Helpers, locking, config parsing
│   ├── routers.sh  # Command routing logic
│   └── commands/
│       ├── misc.sh       # Status, Help, Version
│       ├── config.sh     # Config and Init
│       └── toggle-vpn.sh # Core On/Off/Toggle logic
└── test/           # BATS unit tests (mocked)
    └── integration/ # Kill-switch suite: real ufw, in a container
```

## Packaging

Everything a package needs goes through standard `make` variables
(`make prefix=/usr DESTDIR="$pkgdir" install`), and `make install` never touches `$HOME`.
Every stable release's page has an AUR `PKGBUILD` built this way, filled in with its version
and the tarball's hash, and signed. [`packaging/`](packaging/) has its template, and how to
publish it.

## Contributing

1. Fork this repository.
2. Create a feature branch.
3. Submit a Pull Request (should pass CI before being merged)

## License: MIT

This software is provided as is without warranty. Use with caution, and verify package signatures. You are free to copy and modify this code.
