# Codex Desktop for Linux

Run [OpenAI Codex Desktop](https://openai.com/codex/) on Linux.

The official Codex Desktop app is macOS-only. This project provides an automated installer that converts the macOS `.dmg` into a working Linux application, then packages that app as a native Linux package.

`codex-update-manager` current crate version: `0.2.1`

SemVer policy for the crate:

- `major` for incompatible CLI, persisted-state, or install-flow changes
- `minor` for compatible feature additions
- `patch` for fixes, docs, and maintenance-only updates

## How It Works

The installer:

1. Extracts the macOS `.dmg` with `7z`
2. Extracts and patches `app.asar`
3. Rebuilds native Node.js modules for Linux
4. Downloads a Linux Electron runtime
5. Writes a Linux launcher into `codex-app/start.sh`
6. Packages `codex-app/` as a Debian, RPM, or pacman package
7. Starts `codex-update-manager` as a `systemd --user` service for local auto-updates

## Prerequisites
```bash
sudo apt install nodejs npm python3 p7zip-full curl build-essential
```

Note: Ubuntu/Pop!_OS package `p7zip-full` is often too old to read modern APFS DMGs.
Install a newer 7-zip (`7zz`) if extraction fails:

```bash
curl -L -o /tmp/7z.tar.xz https://www.7-zip.org/a/7z2409-linux-x64.tar.xz
tar -C /tmp -xf /tmp/7z.tar.xz
sudo install -m 755 /tmp/7zz /usr/local/bin/7zz
```

### Fedora

You need **Node.js 20+**, **npm**, **Python 3**, **7z**, **curl**, build tools (`gcc`/`g++`/`make`), and **Rust** (`cargo`) for the updater crate and local package rebuilds.

The easiest way to install the required system packages is:

```bash
bash scripts/install-deps.sh
```

That helper detects `apt`, `dnf5`, `dnf`, or `pacman`, installs the system dependencies, and bootstraps Rust through `rustup` if needed.

### Arch Linux

```bash
bash scripts/install-deps.sh
```

Or manually:

```bash
sudo pacman -S --needed nodejs npm python p7zip curl unzip base-devel
```

You also need the **Rust toolchain** for the updater crate:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### NixOS

A Nix flake is provided that handles dependencies and patches Electron for
NixOS:

```bash
nix run github:ilysenko/codex-desktop-linux
```

This installs the app into `codex-app/` in the current directory. You can also
enter a dev shell with the required tooling:

```bash
nix develop github:ilysenko/codex-desktop-linux
```

To add it to a system flake, include this repo as an input and expose the
installer package in `environment.systemPackages`, then run
`codex-desktop-installer` after rebuilding.


You also need the **Codex CLI**:

```bash
npm i -g @openai/codex
```

## Installation

### Auto-download DMG

```bash
git clone https://github.com/ilysenko/codex-desktop-linux.git
cd codex-desktop-linux
chmod +x install.sh
./install.sh
```

### Use your own DMG

```bash
./install.sh /path/to/Codex.dmg
```

## Usage

After installation, launch the generated app from `codex-app/start.sh`:

```bash
./codex-app/start.sh
```

If you prefer an alias:

```bash
echo 'alias codex-desktop="~/codex-desktop-linux/codex-app/start.sh"' >> ~/.bashrc
```

## Native Packages

The repository can build a Debian, RPM, or pacman package from the generated `codex-app/` directory.

### Debian

```bash
./scripts/build-deb.sh
```

Output:

```bash
dist/codex-desktop_YYYY.MM.DD.HHMMSS_amd64.deb
```

Install it with:

```bash
sudo dpkg -i dist/codex-desktop_*.deb
```

### RPM

```bash
./scripts/build-rpm.sh
```

Output:

```bash
dist/codex-desktop-YYYY.MM.DD.HHMMSS-<release>.x86_64.rpm
```

Install it with:

```bash
sudo rpm -Uvh dist/codex-desktop-*.rpm
```

### Arch Linux (pacman)

```bash
./scripts/build-pacman.sh
```

Output:

```bash
dist/codex-desktop-YYYY.MM.DD.HHMMSS-1-x86_64.pkg.tar.zst
```

Install it with:

```bash
sudo pacman -U dist/codex-desktop-*.pkg.tar.zst
```

### Makefile shortcuts

```bash
make check
make test
make build-updater
make build-app
make deb
make rpm
make pacman
make package
make install
make clean-dist
make clean-state
```

`make package` auto-detects the native package manager available on the host and builds the matching package type (Debian, RPM, or pacman).

## Update Manager

The package installs a companion service named `codex-update-manager`.

- It runs as a `systemd --user` service.
- The launcher starts it in best-effort mode on first app launch.
- It checks the upstream `Codex.dmg` on startup and every 6 hours.
- When a new DMG is detected, it rebuilds a local native package using the bundled `update-builder` files under `/opt/codex-desktop/update-builder`.
- If the app is open, the update stays pending until the Electron process exits.
- When the app is closed, the service requests elevation with `pkexec` only for the final install step.
- If the privileged install fails or the auth dialog is dismissed, the updater stays in `failed` instead of re-prompting every 15 seconds.
- Package removal now makes a best-effort attempt to stop and disable the user service for active desktop sessions.

You can inspect the service state with:

```bash
systemctl --user status codex-update-manager.service
codex-update-manager status --json
```

Runtime files live in the standard XDG locations:

```bash
~/.config/codex-update-manager/config.toml
~/.local/state/codex-update-manager/state.json
~/.local/state/codex-update-manager/service.log
~/.cache/codex-update-manager/
```

The Electron launcher also writes:

```bash
~/.local/state/codex-desktop/app.pid
```

That PID file lets the updater know whether Electron is still running before it attempts to install a pending package.

## Technical Notes

The macOS Codex app is an Electron application. The core code (`app.asar`) is platform-independent JavaScript, but it bundles macOS-native modules and a macOS Electron binary.

The installer replaces the macOS Electron with a Linux build and recompiles the native modules using `@electron/rebuild`. The `sparkle` module is removed because it is macOS-only.

The extracted app expects a local webview origin on `localhost:5175`, so the current launcher starts `python3 -m http.server 5175` from `content/webview/`, waits for the socket to become reachable, and only then launches Electron. That is a compatibility workaround for the extracted build, not a final architectural goal.

The current evaluation for a future Rust replacement lives in `docs/webview-server-evaluation.md`.

Native-package-only launcher behavior such as desktop-entry hints and `codex-update-manager` session bootstrapping now lives in `packaging/linux/codex-packaged-runtime.sh`, which the generated launcher loads only when present inside a packaged install.

The launcher also writes logs to:

```bash
~/.cache/codex-desktop/launcher.log
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Error: write EPIPE` | Run `start.sh` directly instead of piping output |
| Blank window | Check whether port 5175 is already in use: `ss -tlnp \| grep 5175` |
| `ERR_CONNECTION_REFUSED` on `:5175` | The webview HTTP server failed to start. Ensure `python3` works and port 5175 is free |
| `CODEX_CLI_PATH` error | Install the CLI with `npm i -g @openai/codex` |
| GPU/Vulkan/Wayland errors | The launcher sets `--ozone-platform-hint=auto`, `--disable-gpu-sandbox`, `--disable-gpu-compositing`, and `--enable-features=WaylandWindowDecorations` by default. If you need X11 explicitly, try `./codex-app/start.sh --ozone-platform=x11` |
| Window flickering | GPU compositing is now disabled by default (`--disable-gpu-compositing`). If flickering persists, try `./codex-app/start.sh --disable-gpu` to fully disable GPU acceleration |
| Sandbox errors | The launcher already sets `--no-sandbox` |
| Stale install / cached DMG | Run `./install.sh --fresh` to remove the existing install dir and re-download the DMG |
| Usage help | Run `./install.sh --help` or `./codex-app/start.sh --help` |
| `codex-update-manager` keeps running after package removal | Run `systemctl --user disable --now codex-update-manager.service` once in the affected session, then confirm `/opt/codex-desktop` is gone |

## Validation

After changing installer, packaging, or updater logic, validate at least:

```bash
bash -n install.sh scripts/build-deb.sh scripts/build-rpm.sh scripts/build-pacman.sh scripts/install-deps.sh
cargo check -p codex-update-manager
cargo test -p codex-update-manager
./scripts/build-deb.sh
dpkg-deb -I dist/codex-desktop_*.deb
dpkg-deb -c dist/codex-desktop_*.deb | sed -n '1,40p'
```

If `rpmbuild` is available, also run:

```bash
./scripts/build-rpm.sh
```

If `makepkg` is available (Arch Linux), also run:

```bash
./scripts/build-pacman.sh
```

If launcher behavior changed, inspect:

```bash
sed -n '1,120p' codex-app/start.sh
```


## Disclaimer

This is an unofficial community project. Codex Desktop is a product of OpenAI. This tool does not redistribute any OpenAI software; it automates the conversion process that users perform on their own copies.

## License

MIT
