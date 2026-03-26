#!/bin/bash
set -Eeuo pipefail

# ============================================================================
# Codex Desktop for Linux — Installer
# Converts the official macOS Codex Desktop app to run on Linux
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${CODEX_INSTALL_DIR:-$SCRIPT_DIR/codex-app}"
ELECTRON_VERSION="40.0.0"
WORK_DIR="$(mktemp -d)"
ARCH="$(uname -m)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'error "Failed at line $LINENO (exit code $?)"' ERR

# ---- Check dependencies ----
check_deps() {
    local missing=()
    for cmd in node npm npx python3 7z curl unzip; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing dependencies: ${missing[*]}
Run the helper to install them automatically:
  bash scripts/install-deps.sh

Or install manually:
  sudo apt install nodejs npm python3 p7zip-full curl unzip build-essential         # Debian/Ubuntu
  sudo dnf install nodejs npm python3 7zip curl unzip @development-tools            # Fedora 41+ (dnf5)
  sudo dnf install nodejs npm python3 p7zip p7zip-plugins curl unzip                # Fedora <41 (dnf)
    && sudo dnf groupinstall 'Development Tools'
  sudo pacman -S nodejs npm python p7zip curl unzip base-devel                      # Arch"
    fi

    NODE_MAJOR=$(node -v | cut -d. -f1 | tr -d v)
    if [ "$NODE_MAJOR" -lt 20 ]; then
        error "Node.js 20+ required (found $(node -v))"
    fi

    if ! command -v make &>/dev/null || ! command -v g++ &>/dev/null; then
        error "Build tools (make, g++) required:
  bash scripts/install-deps.sh                                          # auto-detect
  sudo apt install build-essential                                       # Debian/Ubuntu
  sudo dnf install @development-tools                                    # Fedora 41+ (dnf5)
  sudo dnf groupinstall 'Development Tools'                              # Fedora <41 (dnf)
  sudo pacman -S base-devel                                              # Arch"
    fi

    info "All dependencies found"
}

# ---- Download or find Codex DMG ----
get_dmg() {
    local dmg_dest="$SCRIPT_DIR/Codex.dmg"

    # Reuse existing DMG
    if [ -s "$dmg_dest" ]; then
        info "Using cached DMG: $dmg_dest ($(du -h "$dmg_dest" | cut -f1))"
        echo "$dmg_dest"
        return
    fi

    info "Downloading Codex Desktop DMG..."
    local dmg_url="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
    info "URL: $dmg_url"

    if ! curl -L --progress-bar --max-time 600 --connect-timeout 30 \
            -o "$dmg_dest" "$dmg_url"; then
        rm -f "$dmg_dest"
        error "Download failed. Download manually and place as: $dmg_dest"
    fi

    if [ ! -s "$dmg_dest" ]; then
        rm -f "$dmg_dest"
        error "Download produced empty file. Download manually and place as: $dmg_dest"
    fi

    info "Saved: $dmg_dest ($(du -h "$dmg_dest" | cut -f1))"
    echo "$dmg_dest"
}

# ---- Extract app from DMG ----
extract_dmg() {
    local dmg_path="$1"
    info "Extracting DMG with 7z..."

    local seven_zip_status=0
    if 7z x -y "$dmg_path" -o"$WORK_DIR/dmg-extract" >&2; then
        seven_zip_status=0
    else
        seven_zip_status=$?
    fi

    local app_dir
    app_dir=$(find "$WORK_DIR/dmg-extract" -maxdepth 3 -name "*.app" -type d | head -1)
    if [ -z "$app_dir" ]; then
        error "Failed to extract DMG"
    fi

    # 7z can return non-zero for non-fatal warnings, such as the DMG's
    # /Applications symlink being skipped as a "dangerous link path".
    if [ "$seven_zip_status" -ne 0 ]; then
        warn "7z reported extraction warnings (exit code $seven_zip_status); continuing"
    fi

    info "Found: $(basename "$app_dir")"
    echo "$app_dir"
}

# ---- Build native modules in a clean directory ----
build_native_modules() {
    local app_extracted="$1"

    # Read versions from extracted app
    local bs3_ver npty_ver
    bs3_ver=$(node -p "require('$app_extracted/node_modules/better-sqlite3/package.json').version" 2>/dev/null || echo "")
    npty_ver=$(node -p "require('$app_extracted/node_modules/node-pty/package.json').version" 2>/dev/null || echo "")

    [ -n "$bs3_ver" ] || error "Could not detect better-sqlite3 version"
    [ -n "$npty_ver" ] || error "Could not detect node-pty version"

    info "Native modules: better-sqlite3@$bs3_ver, node-pty@$npty_ver"

    # Build in a CLEAN directory (asar doesn't have full source)
    local build_dir="$WORK_DIR/native-build"
    mkdir -p "$build_dir"
    cd "$build_dir"

    echo '{"private":true}' > package.json

    info "Installing fresh sources from npm..."
    npm install "electron@$ELECTRON_VERSION" --save-dev --ignore-scripts 2>&1 >&2
    npm install "better-sqlite3@$bs3_ver" "node-pty@$npty_ver" --ignore-scripts 2>&1 >&2

    info "Compiling for Electron v$ELECTRON_VERSION (this takes ~1 min)..."
    npx --yes @electron/rebuild -v "$ELECTRON_VERSION" --force 2>&1 >&2

    info "Native modules built successfully"

    # Copy compiled modules back into extracted app
    rm -rf "$app_extracted/node_modules/better-sqlite3"
    rm -rf "$app_extracted/node_modules/node-pty"
    cp -r "$build_dir/node_modules/better-sqlite3" "$app_extracted/node_modules/"
    cp -r "$build_dir/node_modules/node-pty" "$app_extracted/node_modules/"
}

# ---- Extract and patch app.asar ----
patch_asar() {
    local app_dir="$1"
    local resources_dir="$app_dir/Contents/Resources"

    [ -f "$resources_dir/app.asar" ] || error "app.asar not found in $resources_dir"

    info "Extracting app.asar..."
    cd "$WORK_DIR"
    npx --yes asar extract "$resources_dir/app.asar" app-extracted

    # Copy unpacked native modules if they exist
    if [ -d "$resources_dir/app.asar.unpacked" ]; then
        cp -r "$resources_dir/app.asar.unpacked/"* app-extracted/ 2>/dev/null || true
    fi

    # Remove macOS-only modules
    rm -rf "$WORK_DIR/app-extracted/node_modules/sparkle-darwin" 2>/dev/null || true
    find "$WORK_DIR/app-extracted" -name "sparkle.node" -delete 2>/dev/null || true

    # Build native modules in clean environment and copy back
    build_native_modules "$WORK_DIR/app-extracted"

    # Repack
    info "Repacking app.asar..."
    cd "$WORK_DIR"
    npx asar pack app-extracted app.asar --unpack "{*.node,*.so,*.dylib}" 2>/dev/null

    info "app.asar patched"
}

# ---- Download Linux Electron ----
download_electron() {
    info "Downloading Electron v${ELECTRON_VERSION} for Linux..."

    local electron_arch
    case "$ARCH" in
        x86_64)  electron_arch="x64" ;;
        aarch64) electron_arch="arm64" ;;
        armv7l)  electron_arch="armv7l" ;;
        *)       error "Unsupported architecture: $ARCH" ;;
    esac

    local url="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-${electron_arch}.zip"

    curl -L --progress-bar -o "$WORK_DIR/electron.zip" "$url"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    unzip -qo "$WORK_DIR/electron.zip"

    info "Electron ready"
}

# ---- Extract webview files ----
extract_webview() {
    local app_dir="$1"
    mkdir -p "$INSTALL_DIR/content/webview"

    # Webview files are inside the extracted asar at webview/
    local asar_extracted="$WORK_DIR/app-extracted"
    if [ -d "$asar_extracted/webview" ]; then
        cp -r "$asar_extracted/webview/"* "$INSTALL_DIR/content/webview/"
        info "Webview files copied"
    else
        warn "Webview directory not found in asar — app may not work"
    fi
}

# ---- Install app.asar ----
install_app() {
    cp "$WORK_DIR/app.asar" "$INSTALL_DIR/resources/"
    if [ -d "$WORK_DIR/app.asar.unpacked" ]; then
        cp -r "$WORK_DIR/app.asar.unpacked" "$INSTALL_DIR/resources/"
    fi
    info "app.asar installed"
}

# ---- Create start script ----
create_start_script() {
    cat > "$INSTALL_DIR/start.sh" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEBVIEW_DIR="$SCRIPT_DIR/content/webview"
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codex-desktop"
LOG_FILE="$LOG_DIR/launcher.log"
APP_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/codex-desktop"
APP_PID_FILE="$APP_STATE_DIR/app.pid"

mkdir -p "$LOG_DIR" "$APP_STATE_DIR"
exec >>"$LOG_FILE" 2>&1

echo "[$(date -Is)] Starting Codex Desktop launcher"

find_codex_cli() {
    if command -v codex >/dev/null 2>&1; then
        command -v codex
        return 0
    fi

    if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
        export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
        # shellcheck disable=SC1090
        . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
        if command -v codex >/dev/null 2>&1; then
            command -v codex
            return 0
        fi
    fi

    local candidate
    for candidate in \
        "$HOME/.nvm/versions/node/current/bin/codex" \
        "$HOME/.nvm/versions/node"/*/bin/codex \
        "$HOME/.local/bin/codex" \
        "/usr/local/bin/codex" \
        "/usr/bin/codex"
    do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

notify_error() {
    local message="$1"
    echo "$message"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send "Codex Desktop" "$message"
    fi
}

clear_stale_pid_file() {
    if [ ! -f "$APP_PID_FILE" ]; then
        return 0
    fi

    local pid=""
    pid="$(cat "$APP_PID_FILE" 2>/dev/null || true)"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$APP_PID_FILE"
    fi
}

ensure_update_manager_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
        return 0
    fi

    if ! systemctl --user show-environment >/dev/null 2>&1; then
        return 0
    fi

    systemctl --user import-environment \
        PATH \
        DISPLAY \
        WAYLAND_DISPLAY \
        DBUS_SESSION_BUS_ADDRESS \
        XAUTHORITY \
        XDG_RUNTIME_DIR >/dev/null 2>&1 || true

    if command -v dbus-update-activation-environment >/dev/null 2>&1; then
        dbus-update-activation-environment --systemd \
            PATH \
            DISPLAY \
            WAYLAND_DISPLAY \
            DBUS_SESSION_BUS_ADDRESS \
            XAUTHORITY \
            XDG_RUNTIME_DIR >/dev/null 2>&1 || true
    fi

    if systemctl --user is-enabled codex-update-manager.service >/dev/null 2>&1; then
        systemctl --user start codex-update-manager.service >/dev/null 2>&1 || true
    else
        systemctl --user enable --now codex-update-manager.service >/dev/null 2>&1 || true
    fi
}

clear_stale_pid_file
ensure_update_manager_service
pkill -f "http.server 5175" 2>/dev/null || true
sleep 0.3

if [ -d "$WEBVIEW_DIR" ] && [ "$(ls -A "$WEBVIEW_DIR" 2>/dev/null)" ]; then
    cd "$WEBVIEW_DIR"
    python3 -m http.server 5175 &> /dev/null &
    HTTP_PID=$!
    trap "kill $HTTP_PID 2>/dev/null" EXIT
fi

if [ -z "${CODEX_CLI_PATH:-}" ]; then
    CODEX_CLI_PATH="$(find_codex_cli || true)"
    export CODEX_CLI_PATH
fi

if [ -z "$CODEX_CLI_PATH" ]; then
    notify_error "Codex CLI not found. Install with: npm i -g @openai/codex"
    exit 1
fi

echo "Using CODEX_CLI_PATH=$CODEX_CLI_PATH"

cd "$SCRIPT_DIR"
echo "$$" > "$APP_PID_FILE"
exec "$SCRIPT_DIR/electron" --no-sandbox --class=codex-desktop --app-id=codex-desktop "$@"
SCRIPT

    chmod +x "$INSTALL_DIR/start.sh"
    info "Start script created"
}

# ---- Main ----
main() {
    echo "============================================" >&2
    echo "  Codex Desktop for Linux — Installer"       >&2
    echo "============================================" >&2
    echo ""                                             >&2

    check_deps

    local dmg_path=""
    if [ $# -ge 1 ] && [ -f "$1" ]; then
        dmg_path="$(realpath "$1")"
        info "Using provided DMG: $dmg_path"
    else
        dmg_path=$(get_dmg)
    fi

    local app_dir
    app_dir=$(extract_dmg "$dmg_path")

    patch_asar "$app_dir"
    download_electron
    extract_webview "$app_dir"
    install_app
    create_start_script

    if ! command -v codex &>/dev/null; then
        warn "Codex CLI not found. Install it: npm i -g @openai/codex"
    fi

    echo ""                                             >&2
    echo "============================================" >&2
    info "Installation complete!"
    echo "  Run:  $INSTALL_DIR/start.sh"                >&2
    echo "============================================" >&2
}

main "$@"
