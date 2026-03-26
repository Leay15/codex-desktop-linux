# Codex Desktop for Linux

Run [OpenAI Codex Desktop](https://openai.com/codex/) on Linux.

The official Codex Desktop app is macOS-only. This project provides an automated installer that converts the macOS `.dmg` into a working Linux application.

## How it works

The installer:

1. Extracts the macOS `.dmg` (using `7z`)
2. Extracts `app.asar` (the Electron app bundle)
3. Rebuilds native Node.js modules (`node-pty`, `better-sqlite3`) for Linux
4. Removes macOS-only modules (`sparkle` auto-updater)
5. Downloads Linux Electron (same version as the app — v40)
6. Repacks everything and creates a launch script

## Prerequisites

**Node.js 20+**, **npm**, **Python 3**, **7z**, **curl**, **build tools** (gcc/g++/make), and **Rust** (cargo — needed to compile the update manager).

Run the helper script to install everything automatically (detects apt / dnf5 / dnf / pacman and installs Rust via rustup):

```bash
bash scripts/install-deps.sh
```

Or install manually for your distro:

### Debian/Ubuntu

```bash
sudo apt install nodejs npm python3 p7zip-full curl unzip build-essential
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### Fedora 41+ (dnf5)

```bash
sudo dnf install nodejs npm python3 7zip curl unzip @development-tools
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### Fedora &lt;41 (dnf)

```bash
sudo dnf install nodejs npm python3 p7zip p7zip-plugins curl unzip
sudo dnf groupinstall 'Development Tools'
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### Arch

```bash
sudo pacman -S nodejs npm python p7zip curl unzip base-devel
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

After installing Rust, apply the PATH change to your current shell:

```bash
source "$HOME/.cargo/env"
```

You also need the **Codex CLI**:

```bash
npm i -g @openai/codex
```

## Installation

### Option A: Auto-download DMG

```bash
git clone https://github.com/ilysenko/codex-desktop-linux.git
cd codex-desktop-linux
chmod +x install.sh
./install.sh
```

### Option B: Provide your own DMG

Download `Codex.dmg` from [openai.com/codex](https://openai.com/codex/), then:

```bash
./install.sh /path/to/Codex.dmg
```

## Usage

The app is installed into `codex-app/` next to the install script:

```bash
codex-desktop-linux/codex-app/start.sh
```

Or add an alias to your shell:

```bash
echo 'alias codex-desktop="~/codex-desktop-linux/codex-app/start.sh"' >> ~/.bashrc
```

## Build a `.deb`

After running the installer and generating `codex-app/`, you can build a Debian package:

```bash
./scripts/build-deb.sh
```

The output is written to `dist/` and can be installed with:

```bash
sudo dpkg -i dist/codex-desktop_*.deb
```

This installs the app under `/opt/codex-desktop`, adds a launcher in `/usr/bin/codex-desktop`,
and registers a desktop entry for app menus.

The package also installs a local update manager:

- `/usr/bin/codex-update-manager`
- `/usr/lib/systemd/user/codex-update-manager.service`
- `/opt/codex-desktop/update-builder/`

The update manager is started on demand by the launcher and is responsible for:

1. checking the upstream DMG on a timer
2. downloading and hashing new DMGs
3. rebuilding a local Linux package with the bundled builder scripts
4. waiting until Codex Desktop is closed
5. installing the rebuilt `.deb` through `pkexec`

### Update manager state

Runtime configuration and state live in standard XDG paths:

```bash
~/.config/codex-update-manager/config.toml
~/.local/state/codex-update-manager/state.json
~/.local/state/codex-update-manager/service.log
~/.cache/codex-update-manager/
```

The Electron launcher also maintains:

```bash
~/.local/state/codex-desktop/app.pid
```

That PID file lets the update manager know whether the Electron app is still running before it attempts to install a pending package.

## Local Update Manager

The Debian package now installs a companion service named `codex-update-manager`.

- It runs as a `systemd --user` service.
- The launcher starts it in best-effort mode on first app launch.
- It checks the upstream `Codex.dmg` on startup and every 6 hours.
- When a new DMG is detected, it rebuilds a Linux `.deb` locally using the bundled
  `update-builder` files under `/opt/codex-desktop/update-builder`.
- If the app is open, the update stays pending until the Electron process exits.
- When the app is closed, the service requests elevation with `pkexec` only for the final
  `apt` or `dpkg` install step.

You can inspect the service state with:

```bash
systemctl --user status codex-update-manager.service
codex-update-manager status --json
```

The updater stores runtime files in:

- `~/.config/codex-update-manager/config.toml`
- `~/.local/state/codex-update-manager/state.json`
- `~/.local/state/codex-update-manager/service.log`
- `~/.cache/codex-update-manager/`

### Custom install directory

```bash
CODEX_INSTALL_DIR=/opt/codex ./install.sh
```

## How it works (technical details)

The macOS Codex app is an Electron application. The core code (`app.asar`) is platform-independent JavaScript, but it bundles:

- **Native modules** compiled for macOS (`node-pty` for terminal emulation, `better-sqlite3` for local storage, `sparkle` for auto-updates)
- **Electron binary** for macOS

The installer replaces the macOS Electron with a Linux build and recompiles the native modules using `@electron/rebuild`. The `sparkle` module (macOS-only auto-updater) is removed since it has no Linux equivalent.

A small Python HTTP server is used as a workaround: when `app.isPackaged` is `false` (which happens with extracted builds), the app tries to connect to a Vite dev server on `localhost:5175`. The HTTP server serves the static webview files on that port.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Error: write EPIPE` | Make sure you're not piping the output — run `start.sh` directly |
| Blank window | Check that port 5175 is not in use: `lsof -i :5175` |
| `CODEX_CLI_PATH` error | Install CLI: `npm i -g @openai/codex` |
| GPU/rendering issues | Try: `./codex-app/start.sh --disable-gpu` |
| Sandbox errors | The `--no-sandbox` flag is already set in `start.sh` |

## Validate the packaged updater

After changing updater or packaging logic, validate at least:

```bash
cargo test -p codex-update-manager
bash -n install.sh
bash -n scripts/build-deb.sh
./scripts/build-deb.sh
dpkg-deb -I dist/codex-desktop_*.deb
dpkg-deb -c dist/codex-desktop_*.deb | rg 'codex-update-manager|update-builder|systemd/user'
```

## Disclaimer

This is an unofficial community project. Codex Desktop is a product of OpenAI. This tool does not redistribute any OpenAI software — it automates the conversion process that users perform on their own copies.

## License

MIT
