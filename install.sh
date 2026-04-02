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

dependency_help() {
    cat <<'EOF'
Run the helper to install them automatically:
  bash scripts/install-deps.sh

Or install manually:
  sudo apt install nodejs npm python3 p7zip-full curl unzip build-essential         # Debian/Ubuntu
  sudo dnf install nodejs npm python3 7zip curl unzip @development-tools            # Fedora 41+ (dnf5)
  sudo dnf install nodejs npm python3 p7zip p7zip-plugins curl unzip                # Fedora <41 (dnf)
    && sudo dnf groupinstall 'Development Tools'
  sudo pacman -S nodejs npm python p7zip curl unzip base-devel                      # Arch
EOF
}

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'error "Failed at line $LINENO (exit code $?)"' ERR

CACHED_DMG_PATH="$SCRIPT_DIR/Codex.dmg"
FRESH_INSTALL=0
REUSE_CACHED_DMG=1
PROVIDED_DMG_PATH=""

usage() {
    cat <<'HELP'
Usage: ./install.sh [OPTIONS] [path/to/Codex.dmg]

Converts the official macOS Codex Desktop app to run on Linux.

Options:
  -h, --help     Show this help message and exit
  --fresh        Remove existing install directory and cached DMG before building
  --reuse-dmg    Reuse cached Codex.dmg if present (default)

Environment variables:
  CODEX_INSTALL_DIR   Override the install directory (default: ./codex-app)

After install, launch with:
  ./codex-app/start.sh
HELP
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --fresh)
                FRESH_INSTALL=1
                REUSE_CACHED_DMG=0
                ;;
            --reuse-dmg)
                REUSE_CACHED_DMG=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                error "Unknown option: $1 (see --help)"
                ;;
            *)
                [ -z "$PROVIDED_DMG_PATH" ] || error "Only one DMG path may be provided"
                PROVIDED_DMG_PATH="$1"
                ;;
        esac
        shift
    done
}

prepare_install() {
    if [ "$FRESH_INSTALL" -eq 1 ] && [ -d "$INSTALL_DIR" ]; then
        info "Removing existing install directory: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi

    if [ "$FRESH_INSTALL" -eq 1 ] && [ "$REUSE_CACHED_DMG" -ne 1 ] && [ -f "$CACHED_DMG_PATH" ]; then
        info "Removing cached DMG: $CACHED_DMG_PATH"
        rm -f "$CACHED_DMG_PATH"
    fi
}

# ---- Check dependencies ----
check_deps() {
    local missing=()
    for cmd in node npm npx python3 7z curl unzip; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing dependencies: ${missing[*]}
$(dependency_help)"
    fi

    NODE_MAJOR=$(node -v | cut -d. -f1 | tr -d v)
    if [ "$NODE_MAJOR" -lt 20 ]; then
        error "Node.js 20+ required (found $(node -v))"
    fi

    if ! command -v make &>/dev/null || ! command -v g++ &>/dev/null; then
        error "Build tools (make, g++) required:
$(dependency_help)"
    fi

    # Prefer modern 7-zip if available (required for APFS DMG)
    if command -v 7zz &>/dev/null; then
        SEVEN_ZIP_CMD="7zz"
    else
        SEVEN_ZIP_CMD="7z"
    fi

    if "$SEVEN_ZIP_CMD" | head -n 1 | grep -q "16.02"; then
        error "Your 7-zip is too old to open modern APFS DMGs.
Install a newer 7-zip (7zz), e.g.:
  curl -L -o /tmp/7z.tar.xz https://www.7-zip.org/a/7z2409-linux-x64.tar.xz
  tar -C /tmp -xf /tmp/7z.tar.xz
  sudo install -m 755 /tmp/7zz /usr/local/bin/7zz"
    fi

    info "All dependencies found (using $SEVEN_ZIP_CMD)"
}

# ---- Download or find Codex DMG ----
get_dmg() {
    local dmg_dest="$CACHED_DMG_PATH"

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

    local extract_dir="$WORK_DIR/dmg-extract"
    local seven_log="$WORK_DIR/7z.log"
    local seven_zip_status=0

    mkdir -p "$extract_dir"
    if "$SEVEN_ZIP_CMD" x -y -snl "$dmg_path" -o"$extract_dir" >"$seven_log" 2>&1; then
        :
    else
        seven_zip_status=$?
    fi

    local app_dir
    app_dir=$(find "$extract_dir" -maxdepth 3 -name "*.app" -type d | head -1)

    if [ "$seven_zip_status" -ne 0 ]; then
        if [ -n "$app_dir" ]; then
            warn "7z exited with code $seven_zip_status but app bundle was found; continuing"
            warn "$(tail -n 5 "$seven_log" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
        else
            cat "$seven_log" >&2
            error "Failed to extract DMG"
        fi
    fi

    [ -n "$app_dir" ] || error "Could not find .app bundle in DMG"

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
PACKAGED_RUNTIME_HELPER="$SCRIPT_DIR/.codex-linux/codex-packaged-runtime.sh"

mkdir -p "$LOG_DIR" "$APP_STATE_DIR"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'HELP'
Usage: ./start.sh [OPTIONS] [-- ELECTRON_FLAGS...]

Launches the Codex Desktop app.

Options:
  -h, --help                  Show this help message and exit
  --disable-gpu               Completely disable GPU acceleration
  --disable-gpu-compositing   Disable GPU compositing (fixes flickering)
  --ozone-platform=x11        Force X11 instead of Wayland

Extra flags are passed directly to Electron.

Logs: ~/.cache/codex-desktop/launcher.log
HELP
    exit 0
fi

exec >>"$LOG_FILE" 2>&1

echo "[$(date -Is)] Starting Codex Desktop launcher"

load_packaged_runtime_helper() {
    if [ -f "$PACKAGED_RUNTIME_HELPER" ]; then
        # shellcheck disable=SC1090
        . "$PACKAGED_RUNTIME_HELPER"
    fi
}

run_packaged_runtime_prelaunch() {
    if declare -F codex_packaged_runtime_prelaunch >/dev/null 2>&1; then
        codex_packaged_runtime_prelaunch
    fi
}

export_packaged_runtime_env() {
    if declare -F codex_packaged_runtime_export_env >/dev/null 2>&1; then
        codex_packaged_runtime_export_env
    fi
}

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
        "$HOME/.local/share/pnpm/codex" \
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

wait_for_webview_server() {
    echo "Waiting for webview server on :5175"

    local attempt
    for attempt in $(seq 1 50); do
        if python3 -c "import socket; s=socket.socket(); s.settimeout(0.5); s.connect(('127.0.0.1', 5175)); s.close()" 2>/dev/null; then
            echo "Webview server is ready"
            return 0
        fi
        sleep 0.1
    done

    return 1
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

load_packaged_runtime_helper
clear_stale_pid_file
run_packaged_runtime_prelaunch
pkill -f "http.server 5175" 2>/dev/null || true
sleep 0.5

if [ -d "$WEBVIEW_DIR" ] && [ "$(ls -A "$WEBVIEW_DIR" 2>/dev/null)" ]; then
    cd "$WEBVIEW_DIR"
    nohup python3 -m http.server 5175 &> /dev/null &
    HTTP_PID=$!
    trap "kill $HTTP_PID 2>/dev/null" EXIT

    # Wait for the HTTP server to be ready (up to 5 seconds)
    echo "Waiting for webview server..."
    for i in $(seq 1 50); do
        if python3 -c "import socket; s=socket.socket(); s.settimeout(0.5); s.connect(('127.0.0.1',5175)); s.close()" 2>/dev/null; then
            echo "Webview server ready."
            break
        fi
        sleep 0.1
    done
fi

if [ -z "${CODEX_CLI_PATH:-}" ]; then
    CODEX_CLI_PATH="$(find_codex_cli || true)"
    export CODEX_CLI_PATH
fi

if [ -z "$CODEX_CLI_PATH" ]; then
    notify_error "Codex CLI not found. Install with: npm i -g @openai/codex"
    exit 1
fi

export_packaged_runtime_env

echo "Using CODEX_CLI_PATH=$CODEX_CLI_PATH"

cd "$SCRIPT_DIR"
echo "$$" > "$APP_PID_FILE"
exec "$SCRIPT_DIR/electron" \
    --no-sandbox \
    --class=Codex \
    --app-id=Codex \
    --ozone-platform-hint=auto \
    --disable-gpu-sandbox \
    --disable-gpu-compositing \
    --enable-features=WaylandWindowDecorations \
    "$@"
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

    parse_args "$@"
    check_deps
    prepare_install

    local dmg_path=""
    if [ -n "$PROVIDED_DMG_PATH" ]; then
        [ -f "$PROVIDED_DMG_PATH" ] || error "Provided DMG not found: $PROVIDED_DMG_PATH"
        dmg_path="$(realpath "$PROVIDED_DMG_PATH")"
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
