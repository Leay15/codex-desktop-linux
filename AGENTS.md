# AGENTS.md

## Purpose

This repository adapts the official macOS Codex Desktop DMG to a runnable Linux build, packages that build as a `.deb`, and now ships a local Rust update manager that rebuilds future Linux packages from newer upstream DMGs.

The current working flow is:

1. `install.sh` extracts `Codex.dmg`
2. extracts and patches `app.asar`
3. rebuilds native Node modules for Linux
4. downloads a Linux Electron runtime
5. writes a Linux launcher into `codex-app/start.sh`
6. `scripts/build-deb.sh` packages `codex-app/` into a Debian package
7. `codex-update-manager` runs as a `systemd --user` service and manages local auto-updates

## Source Of Truth

- `install.sh`
  Main installer and launcher generator.
- `scripts/build-deb.sh`
  Builds the `.deb` from the already-generated `codex-app/`.
- `packaging/linux/control`
  Debian control template.
- `packaging/linux/codex-desktop.desktop`
  Desktop entry template.
- `packaging/linux/codex-update-manager.service`
  User-level `systemd` unit for the local update manager.
- `assets/codex.png`
  App icon used in the `.deb`.
- `updater/`
  Rust crate that checks for new upstream DMGs, rebuilds local `.deb` artifacts, tracks update state, and installs prepared packages after the app exits.

## Generated Artifacts

- `codex-app/`
  Generated Linux app directory. Treat this as build output unless you are intentionally patching the launcher or testing package contents.
- `dist/`
  Generated packaging output, including `dist/codex-desktop_*.deb`.
- `Codex.dmg`
  Cached upstream DMG. Useful for repeat installs.
- `~/.config/codex-update-manager/config.toml`
  Runtime config written or read by the updater service.
- `~/.local/state/codex-update-manager/state.json`
  Updater state machine persistence.
- `~/.local/state/codex-update-manager/service.log`
  Updater service log.
- `~/.cache/codex-update-manager/`
  Downloaded DMGs, rebuild workspaces, staged `.deb` artifacts, and build logs.

Do not assume `codex-app/` is pristine. If behavior differs from `install.sh`, prefer updating `install.sh` and then regenerating the app.

## Important Behavior And Known Fixes

- DMG extraction:
  `7z` can return a non-zero status for the `/Applications` symlink inside the DMG. This is currently treated as a warning if a `.app` bundle was still extracted successfully.
- Launcher and `nvm`:
  GUI launchers often do not inherit the user's shell `PATH`. The generated `start.sh` explicitly searches for `codex`, including common `nvm` locations.
- Launcher logging:
  The generated launcher logs to:
  `~/.cache/codex-desktop/launcher.log`
- App liveness:
  The launcher writes a PID file to `~/.local/state/codex-desktop/app.pid`. The updater uses that plus `/proc` fallback to know whether Electron is still running.
- Desktop icon association:
  The launcher runs Electron with `--class=codex-desktop`, and the desktop file sets `StartupWMClass=codex-desktop` so the taskbar/dock can associate the correct icon.
- Webview server:
  The launcher starts a local `python3 -m http.server 5175` from `content/webview/` because the extracted app expects local webview assets there.
- Closing behavior:
  If future work touches shutdown behavior, assume the confirmation dialog may be implemented inside the app bundle rather than the Linux launcher.
- Update manager:
  The `.deb` includes `/usr/bin/codex-update-manager`, `/usr/lib/systemd/user/codex-update-manager.service`, and a minimal rebuild bundle under `/opt/codex-desktop/update-builder`.
- Privilege boundary:
  The updater runs unprivileged. It only escalates at install time via `pkexec /usr/bin/codex-update-manager install-deb --path <deb>`.

## How To Rebuild

### Regenerate the Linux app

```bash
./install.sh ./Codex.dmg
```

Or let the script download the DMG:

```bash
./install.sh
```

### Build the Debian package

```bash
./scripts/build-deb.sh
```

Default output:

```bash
dist/codex-desktop_YYYY.MM.DD.HHMMSS_amd64.deb
```

Optional version override:

```bash
PACKAGE_VERSION=2026.03.24.120000+deadbeef ./scripts/build-deb.sh
```

## Runtime Expectations

- `node`, `npm`, `npx`, `python3`, `7z`, `curl`, `unzip`, `make`, and `g++` are required for `install.sh`
- Node.js 20+ is required
- the packaged app still requires the Codex CLI at runtime:
  `codex` must exist in `PATH` or be set through `CODEX_CLI_PATH`

## Packaging Notes

The `.deb` currently installs:

- app files under `/opt/codex-desktop`
- launcher under `/usr/bin/codex-desktop`
- updater binary under `/usr/bin/codex-update-manager`
- updater unit under `/usr/lib/systemd/user/codex-update-manager.service`
- update builder bundle under `/opt/codex-desktop/update-builder`
- desktop file under `/usr/share/applications/codex-desktop.desktop`
- icon under `/usr/share/icons/hicolor/256x256/apps/codex-desktop.png`

The builder uses `dpkg-deb --root-owner-group` so package ownership is correct.

## Preferred Validation After Changes

After editing installer or packaging logic, validate at least:

```bash
bash -n install.sh
bash -n scripts/build-deb.sh
cargo check -p codex-update-manager
cargo test -p codex-update-manager
./scripts/build-deb.sh
dpkg-deb -I dist/codex-desktop_*.deb
dpkg-deb -c dist/codex-desktop_*.deb | sed -n '1,40p'
```

If launcher behavior changed, also inspect:

```bash
sed -n '1,120p' codex-app/start.sh
```

If updater behavior changed, also inspect:

```bash
systemctl --user status codex-update-manager.service
codex-update-manager status --json
sed -n '1,120p' ~/.local/state/codex-update-manager/state.json
sed -n '1,160p' ~/.local/state/codex-update-manager/service.log
```

## Editing Guidance

- Prefer changing `install.sh` over manually patching `codex-app/start.sh`, unless you are making a temporary local test.
- If you update the launcher template inside `install.sh`, regenerate `codex-app/` or keep `codex-app/start.sh` aligned before building a new `.deb`.
- Keep packaging changes in `packaging/linux/` and `scripts/build-deb.sh`; avoid hardcoding distro-specific behavior outside those files unless necessary.
