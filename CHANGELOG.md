# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.4.0] - 2026-04-13

### Added

- Automatic Codex CLI installation during launcher preflight when the CLI is missing, exposed through the updater `cli-preflight --allow-install-missing` flow.
- Linux `Open in File Manager` integration in the patched app bundle.
- Launcher-side webview origin validation before Electron starts, with clearer diagnostics when port `5175` serves the wrong content or exits early.
- Expanded smoke coverage for Linux launcher generation and UI patching behavior.

### Changed

- Linux ASAR patching now also adjusts shell behavior, window icon handling, and default opaque window settings on Linux when the user has not explicitly chosen a translucent sidebar preference yet.
- Desktop notifications now resolve icons from packaged, system, and repository locations and send them as file URIs for better desktop-environment compatibility.
- `scripts/install-deps.sh` now owns the `7zz` bootstrap flow, probes pinned upstream tarballs newest-first with `HEAD` checks, and installs to `~/.local/bin` by default unless `SEVENZIP_SYSTEM_INSTALL=1`.
- Updated bundled dependencies and metadata: Electron `40.8.5`, `tokio` `1.51.1`, `windows-sys` `0.61.2`, and `codex-update-manager` `0.4.0`.

### Fixed

- Avoid Linux startup failures caused by stale minified symbol assumptions in the window icon patch (`t.join is not a function`).
- Make updater SHA-256 formatting deterministic so downloaded DMGs produce stable candidate versions and comparisons.
- Prevent `bootstrap_7zz` from warning on unsupported architectures when a working `7zz` or a new enough system `7z` is already available.
- Keep the Linux file manager patch fail-soft when upstream minified bundles drift while still validating that the expected Linux hooks were actually applied.

## [0.3.2] - 2026-04-07

### Fixed

- Fix transparent background flickering on Linux when moving the window or hovering over the sidebar. The upstream Electron app sets `backgroundColor: '#00000000'` (fully transparent) for non-Windows platforms, relying on macOS vibrancy. Linux has no compositor equivalent, causing the desktop to bleed through. The main bundle is now patched to use opaque theme-aware colors (`#000000` dark / `#f9f9f9` light) on Linux.
- Replace transparent startup background in `index.html` with `#1e1e1e` to prevent flash of transparency during app load.

## [0.3.1] - 2026-04-07

### Added

- CLI preflight: before Electron launches, the updater verifies the installed Codex CLI and updates it if a newer npm version is available. Uses a 1-hour cooldown for registry checks and falls back to `npm install -g --prefix ~/.local` if global install fails. Warns instead of blocking app launch on failure.
- Interrupted install recovery: if updater state is left in `Installing` after a crash or restart, the daemon now recovers automatically instead of getting stuck.
- Notification icon resolution chain: bundled, system, repo, then fallback name.
- Makefile targets: `run-app`, `service-enable`, `service-status`.

### Fixed

- `npm install -g` now falls back to `--prefix ~/.local` when global install requires root.

## [0.2.1] - 2026-04-02

### Added

- Native Arch Linux (pacman) package support for updater and install flow.
- Updater builder bundle fix for Arch rebuilds.
- User-local desktop integration (desktop entry, icon, systemd service for non-root installs).

### Fixed

- GPU compositing flickering: added `--disable-gpu-compositing` Electron flag.
- Recoverable 7z warnings handled; added `--fresh` / `--reuse-dmg` flags to installer.
- Graceful patching in `patch-linux-window-ui.js` (warn + skip instead of throw).

## [0.2.0] - 2026-03-27

### Added

- Fedora/RPM packaging support and update manager RPM integration.
- `scripts/install-deps.sh` for automated dependency installation.
- Shared native builders and hardened launcher startup.
- Packaged runtime helper (`codex-packaged-runtime.sh`).
- Failed privileged install no longer auto-retries every reconcile cycle.

### Fixed

- Privilege escalation uses installed binary for self-update.
- Pending install recovery from failed state.
- NVM toolchain preferred for service rebuilds.

## [0.1.0] - 2026-03-20

### Added

- Initial release: automated macOS DMG to Linux Electron app conversion.
- Debian (`.deb`) packaging.
- `codex-update-manager` daemon with systemd user service.
- Upstream DMG detection, local rebuild, and pending install flow.
- Nix flake for NixOS support.
- Wayland and X11 support with GPU error workarounds.
