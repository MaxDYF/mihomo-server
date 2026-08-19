<h1 align="center">mihomo-server</h1>

<h4 align="center">A Bash-based terminal proxy management suite for Mihomo (Clash Meta)</h4>

<p align="center">
  <img src="https://img.shields.io/badge/shell-bash-4EAA25?style=flat-square">
  <img src="https://img.shields.io/badge/core-mihomo-00b4f0?style=flat-square">
  <img src="https://img.shields.io/badge/license-MIT-3da639?style=flat-square">
</p>

`mihomo-server` is a pure-Bash control script for Mihomo. Load it with `source` and control your proxy from the terminal:

- `vpn` — proxy process and terminal proxy control (`on`/`off`/`stop`/`restart`/`status`/`test`/`log`)
- `vpn sub` — subscription management: add, switch, update, and auto-update (`list`/`add`/`use`/`update`/`remove`/`auto`)

No GUI required. Only depends on `curl`, `python3`, and the `mihomo` binary.

## Features

- **One-command proxy**: `vpn on` starts Mihomo and enables the terminal proxy; `vpn off` disables the proxy without killing the process
- **Multiple subscriptions**: keep several airport/provider subscriptions and switch with `vpn sub use`
- **Subscription format support**: Clash YAML / plain proxy lists / base64 subscriptions / `sub://` links / JSON
- **Auto-update**: with `vpn sub auto on`, `vpn on` / `vpn restart` automatically check for stale subscriptions (default 24h) and refresh silently
- **Generated config**: `config.yaml` is generated from `config.base.yaml` plus the active subscription's proxy-providers; manual settings like dns/rules/ports are preserved
- **Smooth migration**: on first run, an existing `config.yaml` is split into a base config + a default subscription (original backed up as `config.yaml.bak-inline`)
- **Safe process control**: PID-file based management avoids killing unrelated processes

## Deployment

### 1. Install dependencies

Ubuntu / Debian:

```bash
sudo apt update && sudo apt install -y curl python3 python3-yaml iproute2
```

Arch Linux:

```bash
sudo pacman -S --needed curl python python-yaml iproute2
```

Fedora:

```bash
sudo dnf install -y curl python3 python3-pyyaml iproute
```

### 2. Install the Mihomo core

Download the latest `linux-amd64` asset from the [Mihomo releases page](https://github.com/MetaCubeX/mihomo/releases/latest) (e.g. `mihomo-linux-amd64-v1.19.11.gz`):

```bash
mkdir -p ~/clash && cd ~/clash
curl -Lo mihomo.gz https://github.com/MetaCubeX/mihomo/releases/download/v1.19.11/mihomo-linux-amd64-v1.19.11.gz
gunzip -f mihomo.gz
chmod +x mihomo
./mihomo -v    # verify
```

> Alternatively, install mihomo from your distro's package manager or mirror the binary into `~/clash/`.

### 3. Clone the repository

```bash
git clone https://github.com/MaxDYF/mihomo-server.git ~/clash
```

> **Migrating from an existing setup?** If you already have a working `config.yaml` (with inline proxies) in `~/clash/`, keep it — the script will automatically split it into a base config + a default subscription on first run (original backed up as `config.yaml.bak-inline`).
>
> If `~/clash/` does not exist yet, the clone above creates it. If it already exists and is not empty, clone into a temp dir and copy the files over instead:
>
> ```bash
> git clone https://github.com/MaxDYF/mihomo-server.git /tmp/mihomo-server
> cp /tmp/mihomo-server/vpn.sh ~/clash/
> ```

### 4. Load the script

Append to `~/.bashrc` (and source it in the current shell):

```bash
echo '[ -f "$HOME/clash/vpn.sh" ] && source "$HOME/clash/vpn.sh"' >> ~/.bashrc
source ~/.bashrc
```

### 5. Add your subscription and start

```bash
vpn sub add "https://your-provider.example/sub?token=xxx" "My Provider"   # add a subscription
vpn sub list        # verify it was downloaded (node count shown)
vpn on              # start the proxy and enable the terminal proxy
vpn status          # check process / ports / subscription status
vpn test            # connectivity test
```

On the first run the script generates a minimal `config.base.yaml` if none exists. Edit it any time to customize `dns`, `rules`, ports, etc. — `config.yaml` is regenerated from it on every subscription switch/update.

### 6. Upgrade

```bash
cd ~/clash && git pull
```

## Quick Start

```bash
vpn on                        # start proxy and enable terminal proxy
vpn sub add "https://example.com/sub?token=xxx" "My Provider"
vpn sub list                  # list subscriptions
vpn sub use My-Provider       # switch subscription
vpn sub update                # manually update the active subscription
vpn status                    # process / port / subscription status
```

## Command Reference

| Command | Description |
| --- | --- |
| `vpn on` / `off` / `stop` | Start proxy + enable terminal proxy / disable terminal proxy only / stop the process |
| `vpn restart` | Restart Mihomo (auto-checks subscription updates) |
| `vpn status` | Process, port, terminal proxy, and subscription status |
| `vpn test` | Connectivity test (Google/GitHub/Baidu) |
| `vpn log [N]` | Show last N log lines |
| `vpn sub list` | List all subscriptions (`*` marks the active one) |
| `vpn sub add <URL> [name]` | Add a subscription |
| `vpn sub use <name\|ID>` | Switch the active subscription |
| `vpn sub update [all\|name\|ID]` | Update subscription(s) |
| `vpn sub remove <name\|ID>` | Remove a subscription |
| `vpn sub auto on\|off` | Toggle auto-update |

## Directory Layout

```
clash/
├── vpn.sh            # main script (loaded via source)
├── config.base.yaml  # base config template (edit dns/rules/ports here)
├── config.yaml       # auto-generated (base + active subscription)
├── subs/             # subscription files and registry
│   ├── subs.list     # subscription registry (id/name/URL/update time)
│   ├── subs.active   # currently active subscription
│   └── subs.auto     # auto-update toggle
└── mihomo            # core binary
```

Files marked with `.gitignore` (`config.yaml`, `config.base.yaml`, `subs/`, logs, the `mihomo` binary, etc.) are local runtime/user data and are not tracked in the repository.

## Requirements

- `bash` 4+
- `mihomo` (Clash Meta core, v1.18+)
- `curl`, `python3` (with PyYAML), `ss` (iproute2)

## License

The scripts are released under the MIT License. The bundled core [Mihomo](https://github.com/MetaCubeX/mihomo) is GPL-3.0; follow its terms when redistributing.