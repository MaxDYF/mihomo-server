<h1 align="center">mihomo-server</h1>

<h4 align="center">A Bash-based terminal proxy management suite for Mihomo (Clash Meta)</h4>

<p align="center">
  <img src="https://img.shields.io/badge/shell-bash-4EAA25?style=flat-square">
  <img src="https://img.shields.io/badge/core-mihomo-00b4f0?style=flat-square">
  <img src="https://img.shields.io/badge/license-MIT-3da639?style=flat-square">
</p>

`mihomo-server` is a pure-Bash control script for Mihomo. Load it with `source` and control your proxy from the terminal:

- `vpn` — proxy process and terminal proxy control (`on`/`off`/`stop`/`restart`/`status`/`test`/`log`)
- `vpn sub` — subscription management: add, import local files, switch, update, and auto-update (`list`/`add`/`import`/`use`/`update`/`remove`/`auto`)

No GUI required. Pure Bash — only depends on `curl` and the `mihomo` binary.

## Features

- **One-command proxy**: `vpn on` starts Mihomo and enables the terminal proxy; `vpn off` disables the proxy without killing the process
- **Multiple subscriptions**: keep several airport/provider subscriptions and switch with `vpn sub use`
- **Offline bootstrap**: import nodes from a working local `config.yaml`, connect, then download online subscriptions
- **Subscription format support**: Clash YAML / plain proxy lists / base64 subscriptions / `sub://` links / JSON
- **Auto-update**: with `vpn sub auto on`, `vpn on` / `vpn restart` automatically check for stale subscriptions (default 24h) and refresh silently
- **Node switching**: `vpn node use` switches the active node instantly via the control API (no restart)
- **Global mode**: `vpn global on` routes all traffic through the selected node
- **Local upstream proxy**: chain subscription nodes through a local SOCKS5/HTTP proxy with `LOCAL_PROXY`
- **Generated config**: `config.yaml` is generated from `config.base.yaml` plus the active subscription's proxy-providers; manual settings like dns/rules/ports are preserved
- **Port management**: ports configurable via env vars or `ports.conf`; every start pre-checks port occupancy and fails fast with a clear reason (shared-server friendly)
- **Smooth migration**: on first run, an existing `config.yaml` is split into a base config + a default subscription (original backed up as `config.yaml.bak-inline`)
- **Safe process control**: PID-file based management avoids killing unrelated processes

## Deployment

### 1. Install dependencies

Ubuntu / Debian:

```bash
sudo apt update && sudo apt install -y curl iproute2
```

Arch Linux:

```bash
sudo pacman -S --needed curl iproute2
```

Fedora:

```bash
sudo dnf install -y curl iproute
```

### 2. Clone anywhere and run the installer

Clone the repository to **any** directory — no need to copy files into your home directory. The installer registers `vpn.sh` in `~/.bashrc` automatically, creates the data directory, and downloads the Mihomo core if it is missing:

```bash
git clone https://github.com/MaxDYF/mihomo-server.git ~/mihomo-server
cd ~/mihomo-server
./install.sh                  # data dir defaults to ~/clash
source ~/.bashrc              # or open a new terminal
```

Options:

```bash
./install.sh --dir ~/myproxy  # custom data directory (exports MIHOMO_DIR in bashrc)
./install.sh --skip-core      # skip downloading the mihomo binary (place it yourself)
./install.sh --help           # show help
```

The installer is idempotent — re-running it never duplicates bashrc entries. Code lives where you cloned it; runtime data (configs, subscriptions, logs, the core binary) lives in the data directory.

> **Migrating from an existing setup?** If you already have a working `~/clash/config.yaml` with inline proxies, keep it — on first run the script splits it into a base config + a default subscription (original backed up as `config.yaml.bak-inline`).

### 3. Add your subscription and start

If this device needs a local proxy to access the subscription URL, configure it first:

```bash
vpn local-proxy on socks5://localhost:9632  # optional; no subscription required
```

```bash
vpn sub add "https://your-provider.example/sub?token=xxx" "My Provider"   # add a subscription
vpn sub list        # verify it was downloaded (node count shown)
vpn on              # start the proxy and enable the terminal proxy
vpn status          # check process / ports / subscription status
vpn test            # connectivity test
```

On a shared server, create `$MIHOMO_DIR/ports.conf` with dedicated ports before starting (see [Ports](#ports)).

On the first run the script generates a minimal `config.base.yaml` if none exists. Edit it any time to customize `dns`, `rules`, etc. — `config.yaml` is regenerated from it on every subscription switch/update.

If you already have a working `config.yaml`, you can import it without downloading a subscription first:

```bash
vpn sub import /path/to/config.yaml "Local Config"
vpn on
vpn sub add "https://your-provider.example/sub?token=xxx" "My Provider"
vpn sub use "My Provider"
```

The import reads the file's actual proxy nodes (`proxies`) into a local subscription and uses the existing `config.base.yaml` for DNS, rules, and ports. The first imported subscription becomes active automatically; importing another one keeps the current selection. Local imports have no update URL and are skipped during updates. A file containing only remote provider URLs needs its nodes downloaded first.

### 4. Upgrade

```bash
cd ~/mihomo-server && git pull    # bashrc 无需改动，重新 source 或新开终端即可
```

## Quick Start

```bash
vpn local-proxy on socks5://localhost:9632  # optional; set before adding a subscription
vpn sub add "https://example.com/sub?token=xxx" "My Provider"
vpn on                        # start proxy and enable terminal proxy
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
| `vpn sub import <file> [name]` | Import nodes from a local `config.yaml` without network access |
| `vpn sub use <name\|ID>` | Switch the active subscription |
| `vpn sub update [all\|name\|ID]` | Update subscription(s) |
| `vpn sub remove <name\|ID>` | Remove a subscription |
| `vpn sub auto on\|off` | Toggle auto-update |
| `vpn node list` | List nodes of the current subscription (`*` marks the active one) |
| `vpn node use <name\|number>` | Switch the active node instantly (no restart) |
| `vpn node auto` | Switch back to auto-select (latency-based) |
| `vpn local-proxy on <URL>` / `off` | Set/disable a local proxy for subscription downloads and node connections (no subscription required) |
| `vpn global on\|off` | Enable/disable global mode (all traffic through the selected node) |

## Directory Layout

Code and data are separated — clone location only holds the scripts:

```
mihomo-server/          # wherever you cloned (bashrc points here)
├── vpn.sh              # main script (loaded via source)
├── install.sh          # one-shot installer (bashrc + data dir + core)
└── install-mihomo.sh   # mihomo core downloader (latest release)

~/clash/                # $MIHOMO_DIR — runtime data (default)
├── config.base.yaml    # base config template (edit dns/rules here)
├── ports.conf          # optional: persistent ports/local proxy settings (KEY=VALUE)
├── config.yaml         # auto-generated (base + active subscription)
├── subs/               # subscription files and registry
│   ├── subs.list       # subscription registry (id/name/URL/update time)
│   ├── subs.active     # currently active subscription
│   └── subs.auto       # auto-update toggle
├── mihomo.log / mihomo.pid / cache.db
└── mihomo              # core binary (downloaded, not tracked)
```

Files marked with `.gitignore` (`config.yaml`, `config.base.yaml`, `subs/`, logs, the `mihomo` binary, etc.) are local runtime/user data and are not tracked in the repository.

## Requirements

- `bash` 4+
- `mihomo` (Clash Meta core, v1.18+)
- `curl`, `ss` (iproute2)

## Ports

Listen ports are configurable with environment variables or `$MIHOMO_DIR/ports.conf` (a `KEY=VALUE` file; environment variables win):

| Variable | Default | Purpose |
| --- | --- | --- |
| `PROXY_PORT` | `7890` | mixed (HTTP+SOCKS) proxy port |
| `SOCKS_PORT` | `7891` | standalone SOCKS5 port |
| `HTTP_PORT` | `7892` | standalone HTTP port |
| `CONTROL_PORT` | `9090` | external controller (REST API) |

The easiest way to configure ports is the built-in command, which persists to `ports.conf` and hot-restarts a running instance:

```bash
vpn port                                  # show current ports and their source
vpn port set 27890                        # change only the mixed proxy port
vpn port set 27890 27891 27892 29090      # set all four
vpn port reset                            # back to defaults
```

Ports set this way are injected into the generated `config.yaml` on every regeneration. Without them, ports configured in `config.base.yaml` are preserved.

Before every start, the script checks each required port: if a port is held by another process (e.g. another user's instance on a shared server), startup aborts with a clear message instead of silently failing to bind. Example `ports.conf`:

```ini
PROXY_PORT=17890
SOCKS_PORT=17891
HTTP_PORT=17892
CONTROL_PORT=19090
```

### Local upstream proxy

Set `LOCAL_PROXY` in `$MIHOMO_DIR/ports.conf` (or export it before sourcing `vpn.sh`), reload `vpn.sh`, and regenerate the config:

```ini
LOCAL_PROXY=socks5://localhost:9632
```

```bash
source /path/to/mihomo-server/vpn.sh
vpn restart
```

You can also set it for the current shell with `vpn local-proxy on socks5://localhost:9632`, or disable it with `vpn local-proxy off`. This works before adding any subscription: subscription downloads and updates use the local proxy immediately, with DNS resolved by the proxy for SOCKS5. Once a subscription is active, changing the local proxy regenerates the config and restarts a running Mihomo instance. Mihomo applies the proxy as `dialer-proxy` to subscription nodes; `DIRECT` rules remain direct.

## License

The scripts are released under the MIT License. The bundled core [Mihomo](https://github.com/MetaCubeX/mihomo) is GPL-3.0; follow its terms when redistributing.
