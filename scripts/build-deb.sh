#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="${APP_DIR_OVERRIDE:-$REPO_DIR/codex-app}"
PKG_ROOT="$REPO_DIR/dist/deb-root"
DIST_DIR="${DIST_DIR_OVERRIDE:-$REPO_DIR/dist}"
CONTROL_TEMPLATE="$REPO_DIR/packaging/linux/control"
DESKTOP_TEMPLATE="$REPO_DIR/packaging/linux/codex-desktop.desktop"
SERVICE_TEMPLATE="$REPO_DIR/packaging/linux/codex-update-manager.service"
ICON_SOURCE="$REPO_DIR/assets/codex.png"

PACKAGE_NAME="${PACKAGE_NAME:-codex-desktop}"
PACKAGE_VERSION="${PACKAGE_VERSION:-$(date -u +%Y.%m.%d.%H%M%S)}"
UPDATER_BINARY_SOURCE="${UPDATER_BINARY_SOURCE:-$REPO_DIR/target/release/codex-update-manager}"
UPDATER_SERVICE_SOURCE="${UPDATER_SERVICE_SOURCE:-$SERVICE_TEMPLATE}"
UPDATE_BUILDER_ROOT="$PKG_ROOT/opt/$PACKAGE_NAME/update-builder"

info()  { echo "[INFO] $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

map_arch() {
    case "$(dpkg --print-architecture)" in
        amd64|arm64|armhf)
            dpkg --print-architecture
            ;;
        *)
            error "Unsupported Debian architecture: $(dpkg --print-architecture)"
            ;;
    esac
}

ensure_updater_binary() {
    if [ -x "$UPDATER_BINARY_SOURCE" ]; then
        return
    fi

    [ -f "$REPO_DIR/Cargo.toml" ] || error "Missing updater binary: $UPDATER_BINARY_SOURCE"
    command -v cargo >/dev/null 2>&1 || error "cargo is required to build codex-update-manager.
Install the Rust toolchain:
  bash scripts/install-deps.sh        # auto-installs via rustup
  # or manually: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"

    info "Building codex-update-manager release binary"
    cargo build --release -p codex-update-manager >&2
    [ -x "$UPDATER_BINARY_SOURCE" ] || error "Failed to build updater binary: $UPDATER_BINARY_SOURCE"
}

main() {
    [ -d "$APP_DIR" ] || error "Missing app directory: $APP_DIR. Run ./install.sh first."
    [ -x "$APP_DIR/start.sh" ] || error "Missing launcher: $APP_DIR/start.sh"
    [ -f "$CONTROL_TEMPLATE" ] || error "Missing control template: $CONTROL_TEMPLATE"
    [ -f "$DESKTOP_TEMPLATE" ] || error "Missing desktop template: $DESKTOP_TEMPLATE"
    [ -f "$UPDATER_SERVICE_SOURCE" ] || error "Missing updater service template: $UPDATER_SERVICE_SOURCE"
    [ -f "$ICON_SOURCE" ] || error "Missing icon: $ICON_SOURCE"
    command -v dpkg-deb >/dev/null 2>&1 || error "dpkg-deb is required"
    command -v dpkg >/dev/null 2>&1 || error "dpkg is required"

    ensure_updater_binary

    local arch output_file
    arch="$(map_arch)"
    output_file="$DIST_DIR/${PACKAGE_NAME}_${PACKAGE_VERSION}_${arch}.deb"

    info "Preparing package root at $PKG_ROOT"
    rm -rf "$PKG_ROOT"
    mkdir -p \
        "$PKG_ROOT/DEBIAN" \
        "$PKG_ROOT/opt" \
        "$PKG_ROOT/usr/bin" \
        "$PKG_ROOT/usr/lib/systemd/user" \
        "$PKG_ROOT/usr/share/applications" \
        "$PKG_ROOT/usr/share/icons/hicolor/256x256/apps"

    cp -a "$APP_DIR" "$PKG_ROOT/opt/$PACKAGE_NAME"
    cp "$DESKTOP_TEMPLATE" "$PKG_ROOT/usr/share/applications/$PACKAGE_NAME.desktop"
    cp "$ICON_SOURCE" "$PKG_ROOT/usr/share/icons/hicolor/256x256/apps/$PACKAGE_NAME.png"
    cp "$UPDATER_BINARY_SOURCE" "$PKG_ROOT/usr/bin/codex-update-manager"
    chmod 0755 "$PKG_ROOT/usr/bin/codex-update-manager"
    cp "$UPDATER_SERVICE_SOURCE" "$PKG_ROOT/usr/lib/systemd/user/codex-update-manager.service"
    chmod 0644 "$PKG_ROOT/usr/lib/systemd/user/codex-update-manager.service"

    mkdir -p "$UPDATE_BUILDER_ROOT/scripts" "$UPDATE_BUILDER_ROOT/packaging/linux" "$UPDATE_BUILDER_ROOT/assets"
    cp "$REPO_DIR/install.sh" "$UPDATE_BUILDER_ROOT/install.sh"
    cp "$REPO_DIR/scripts/build-deb.sh" "$UPDATE_BUILDER_ROOT/scripts/build-deb.sh"
    cp "$REPO_DIR/scripts/build-rpm.sh" "$UPDATE_BUILDER_ROOT/scripts/build-rpm.sh"
    cp "$REPO_DIR/packaging/linux/control" "$UPDATE_BUILDER_ROOT/packaging/linux/control"
    cp "$REPO_DIR/packaging/linux/codex-desktop.spec" "$UPDATE_BUILDER_ROOT/packaging/linux/codex-desktop.spec"
    cp "$REPO_DIR/packaging/linux/codex-desktop.desktop" "$UPDATE_BUILDER_ROOT/packaging/linux/codex-desktop.desktop"
    cp "$UPDATER_SERVICE_SOURCE" "$UPDATE_BUILDER_ROOT/packaging/linux/codex-update-manager.service"
    cp "$REPO_DIR/assets/codex.png" "$UPDATE_BUILDER_ROOT/assets/codex.png"

    cat > "$PKG_ROOT/usr/bin/$PACKAGE_NAME" <<SCRIPT
#!/bin/bash
exec /opt/$PACKAGE_NAME/start.sh "\$@"
SCRIPT
    chmod 0755 "$PKG_ROOT/usr/bin/$PACKAGE_NAME"

    sed \
        -e "s/__VERSION__/$PACKAGE_VERSION/g" \
        -e "s/__ARCH__/$arch/g" \
        "$CONTROL_TEMPLATE" > "$PKG_ROOT/DEBIAN/control"
    chmod 0644 "$PKG_ROOT/DEBIAN/control"

    mkdir -p "$DIST_DIR"
    info "Building $output_file"
    dpkg-deb --root-owner-group --build "$PKG_ROOT" "$output_file" >&2
    info "Built package: $output_file"
}

main "$@"
