#!/bin/bash
set -Eeuo pipefail

# ============================================================================
# Codex Desktop for Linux — Installer
# Converts the official macOS Codex Desktop app to run on Linux
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_APP_ID="${CODEX_APP_ID:-codex-desktop}"
CODEX_APP_DISPLAY_NAME="${CODEX_APP_DISPLAY_NAME:-Codex Desktop}"
INSTALL_ROOT="${CODEX_INSTALL_ROOT:-$SCRIPT_DIR}"
DEFAULT_INSTALL_DIR_NAME="codex-app"
DEFAULT_CODEX_WEBVIEW_PORT=5175
if [ "$CODEX_APP_ID" != "codex-desktop" ]; then
    DEFAULT_INSTALL_DIR_NAME="$CODEX_APP_ID-app"
    DEFAULT_CODEX_WEBVIEW_PORT=5176
fi
INSTALL_DIR="${CODEX_INSTALL_DIR:-$INSTALL_ROOT/$DEFAULT_INSTALL_DIR_NAME}"
CODEX_WEBVIEW_PORT="${CODEX_WEBVIEW_PORT:-$DEFAULT_CODEX_WEBVIEW_PORT}"
ELECTRON_VERSION="41.3.0"
WORK_DIR="$(mktemp -d)"
ARCH="$(uname -m)"
ICON_SOURCE="$SCRIPT_DIR/assets/codex.png"

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
  # Debian/Ubuntu: install Node.js 20+ with npm/npx from NodeSource, nvm, or another compatible source, then:
  sudo apt install python3 p7zip-full curl unzip build-essential                   # Debian/Ubuntu
  sudo dnf install nodejs npm python3 7zip curl unzip @development-tools            # Fedora 41+ (dnf5)
  sudo dnf install nodejs npm python3 p7zip p7zip-plugins curl unzip                # Fedora <41 (dnf)
    && sudo dnf groupinstall 'Development Tools'
  sudo pacman -S nodejs npm python p7zip curl unzip zstd base-devel                 # Arch
  sudo zypper install nodejs-default npm-default python3 p7zip-full curl unzip      # openSUSE
    && sudo zypper install -t pattern devel_basis
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
  CODEX_INSTALL_ALLOW_RUNNING=1
                      Allow overwriting INSTALL_DIR while Codex is running
  CODEX_APP_ID        Override Linux app id/bin identity (default: codex-desktop)
  CODEX_APP_DISPLAY_NAME
                      Override display name (default: Codex Desktop)
  CODEX_WEBVIEW_PORT  Override webview HTTP port (default: 5175, or 5176 for non-default app ids)

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

validate_app_identity() {
    case "$CODEX_APP_ID" in
        ""|*[^A-Za-z0-9._-]*)
            error "CODEX_APP_ID must contain only letters, numbers, dots, underscores, and hyphens"
            ;;
    esac

    [ -n "$CODEX_APP_DISPLAY_NAME" ] || error "CODEX_APP_DISPLAY_NAME must not be empty"

    case "$CODEX_WEBVIEW_PORT" in
        ""|*[!0-9]*)
            error "CODEX_WEBVIEW_PORT must be a TCP port number"
            ;;
    esac
    if [ "$CODEX_WEBVIEW_PORT" -lt 1 ] || [ "$CODEX_WEBVIEW_PORT" -gt 65535 ]; then
        error "CODEX_WEBVIEW_PORT must be between 1 and 65535"
    fi
}

shell_quote() {
    printf '%q' "$1"
}

canonical_path() {
    realpath -m "$1"
}

pid_is_current_user() {
    local pid="$1"
    local uid

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ -d "/proc/$pid" ] || return 1
    uid="$(awk '/^Uid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)"
    [ "$uid" = "$(id -u)" ]
}

# Electron helper processes (renderer, gpu-process, utility, zygote, ...)
# all carry their role as a `--type=...` argv entry. Only the main app
# process omits it, so we use this to skip orphaned helpers that survive
# their parent and re-attach to systemd.
pid_is_electron_helper() {
    local pid="$1"
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -q '^--type='
}

pid_matches_install_target() {
    local pid="$1"
    local expected="$2"
    local actual

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ -d "/proc/$pid" ] || return 1
    pid_is_current_user "$pid" || return 1
    actual="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    [ -n "$actual" ] || return 1
    [ "$actual" = "$(canonical_path "$expected")" ] || return 1
    ! pid_is_electron_helper "$pid"
}

find_running_install_target_pid() {
    local electron_path="$INSTALL_DIR/electron"
    local app_pid_file="${XDG_STATE_HOME:-$HOME/.local/state}/$CODEX_APP_ID/app.pid"
    local pid
    local proc_exe

    [ -e "$electron_path" ] || return 1

    if [ -f "$app_pid_file" ]; then
        pid="$(cat "$app_pid_file" 2>/dev/null || true)"
        if pid_matches_install_target "$pid" "$electron_path"; then
            echo "$pid"
            return 0
        fi
    fi

    for proc_exe in /proc/[0-9]*/exe; do
        [ -e "$proc_exe" ] || continue
        pid="${proc_exe#/proc/}"
        pid="${pid%/exe}"
        if pid_matches_install_target "$pid" "$electron_path"; then
            echo "$pid"
            return 0
        fi
    done

    return 1
}

assert_install_target_not_running() {
    local pid

    if [ "${CODEX_INSTALL_ALLOW_RUNNING:-0}" = "1" ]; then
        warn "CODEX_INSTALL_ALLOW_RUNNING=1 set; installer may overwrite a running Codex app"
        return 0
    fi

    if pid="$(find_running_install_target_pid)"; then
        error "Codex Desktop is currently running from $INSTALL_DIR (pid $pid).
Close that app before rebuilding this install directory, or build into a separate path:
  CODEX_INSTALL_DIR=/tmp/codex-app-build ./install.sh

Set CODEX_INSTALL_ALLOW_RUNNING=1 only if you intentionally want to overwrite a running app."
    fi
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

    if "$SEVEN_ZIP_CMD" 2>&1 | grep -m 1 "7-Zip" | grep -q "16.02"; then
        error "System 7-zip is too old for modern APFS DMGs.
Install a newer 7zz first by running:
  bash scripts/install-deps.sh

That helper bootstraps a current 7zz into ~/.local/bin by default.
If ~/.local/bin is not on your PATH, add it before re-running this script:
  export PATH=\"$HOME/.local/bin:$PATH\"
Set SEVENZIP_SYSTEM_INSTALL=1 to install into /usr/local/bin instead."
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

# ---- Detect Electron version from DMG ----
sanitize_electron_version() {
    local value="$1"
    value="${value#v}"
    value="${value#^}"
    value="${value#~}"

    if [[ "$value" =~ ^[0-9]+(\.[0-9]+){2}([.-][0-9A-Za-z]+)*$ ]]; then
        echo "$value"
        return 0
    fi

    return 1
}

detect_electron_version() {
    local app_dir="$1"
    local detected=""
    local detected_version=""
    local plist_file="$app_dir/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist"

    if [ -f "$plist_file" ]; then
        detected=$(python3 - "$plist_file" <<'PY' 2>/dev/null || true
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    print(plistlib.load(handle).get("CFBundleVersion", ""))
PY
)
        if detected_version=$(sanitize_electron_version "$detected"); then
            ELECTRON_VERSION="$detected_version"
            info "Detected Electron version from DMG: $ELECTRON_VERSION"
            return 0
        elif [ -n "$detected" ]; then
            warn "Ignoring invalid Electron version from DMG: $detected"
        fi
    fi

    local resources_dir="$app_dir/Contents/Resources"
    if [ -f "$resources_dir/app.asar" ]; then
        detected=$(npx --yes asar extract-file "$resources_dir/app.asar" package.json 2>/dev/null |
            node -e '
const fs = require("node:fs");
const pkg = JSON.parse(fs.readFileSync(0, "utf8"));
process.stdout.write(String(pkg.devDependencies?.electron ?? pkg.dependencies?.electron ?? ""));
' 2>/dev/null || true)
        if detected_version=$(sanitize_electron_version "$detected"); then
            ELECTRON_VERSION="$detected_version"
            info "Detected Electron version from package.json: $ELECTRON_VERSION"
            return 0
        elif [ -n "$detected" ]; then
            warn "Ignoring invalid Electron version from package.json: $detected"
        fi
    fi

    warn "Could not auto-detect Electron version; using fallback $ELECTRON_VERSION"
    return 0
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

    info "Patching Linux window and shell behavior..."
    node "$SCRIPT_DIR/scripts/patch-linux-window-ui.js" "$WORK_DIR/app-extracted"

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
        # Replace transparent startup background with an opaque color for Linux.
        # The upstream app relies on macOS vibrancy for the transparent effect;
        # on Linux the transparent background causes flickering.
        local webview_index="$INSTALL_DIR/content/webview/index.html"
        if [ -f "$webview_index" ]; then
            sed -i 's/--startup-background: transparent/--startup-background: #1e1e1e/' "$webview_index"
        fi
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

# ---- Install Linux-safe bundled plugin resources ----
find_cargo_for_linux_computer_use() {
    if command -v cargo >/dev/null 2>&1; then
        command -v cargo
        return 0
    fi

    if [ -x "$HOME/.cargo/bin/cargo" ]; then
        echo "$HOME/.cargo/bin/cargo"
        return 0
    fi

    return 1
}

build_linux_computer_use_backend() {
    local crate_dir="$SCRIPT_DIR/computer-use-linux"
    local backend_binary="$SCRIPT_DIR/target/release/codex-computer-use-linux"
    local cargo_cmd=""

    if [ ! -d "$crate_dir" ]; then
        warn "Linux Computer Use backend source not found at $crate_dir"
        return 1
    fi

    if ! cargo_cmd="$(find_cargo_for_linux_computer_use)"; then
        warn "cargo not found; Linux Computer Use plugin will be unavailable"
        return 1
    fi

    info "Building Linux Computer Use backend..."
    if ! (cd "$SCRIPT_DIR" && "$cargo_cmd" build --release -p codex-computer-use-linux >&2); then
        warn "Failed to build Linux Computer Use backend"
        return 1
    fi

    [ -x "$backend_binary" ] || {
        warn "Linux Computer Use backend binary missing after build: $backend_binary"
        return 1
    }

    echo "$backend_binary"
}

stage_linux_computer_use_plugin() {
    local target_plugins="$1"
    local plugin_template="$SCRIPT_DIR/plugins/openai-bundled/plugins/computer-use"
    local backend_binary=""
    local target_plugin="$target_plugins/computer-use"

    if [ ! -d "$plugin_template" ]; then
        warn "Linux Computer Use plugin template not found at $plugin_template"
        return 1
    fi

    if ! backend_binary="$(build_linux_computer_use_backend)"; then
        return 1
    fi

    rm -rf "$target_plugin"
    mkdir -p "$target_plugin"
    cp -R "$plugin_template/." "$target_plugin/"
    mkdir -p "$target_plugin/bin"
    cp "$backend_binary" "$target_plugin/bin/codex-computer-use-linux"
    chmod 0755 "$target_plugin/bin/codex-computer-use-linux"

    if [ -f "$ICON_SOURCE" ]; then
        mkdir -p "$target_plugin/assets"
        cp "$ICON_SOURCE" "$target_plugin/assets/app-icon.png"
    fi

    find "$target_plugin" \( -name '*:com.apple.*' -o -name '.gitkeep' \) -delete
    return 0
}

is_elf_executable() {
    local file="$1"
    python3 - "$file" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    sys.exit(0 if path.read_bytes()[:4] == b"\x7fELF" else 1)
except OSError:
    sys.exit(1)
PY
}

install_linux_executable_resource() {
    local source="$1"
    local destination="$2"
    local label="$3"

    if [ ! -f "$source" ]; then
        warn "Browser Use $label not found in upstream resources; skipping"
        return 1
    fi

    if ! is_elf_executable "$source"; then
        warn "Browser Use $label is not a Linux executable; skipping"
        return 1
    fi

    install -m 0755 "$source" "$destination"
}

remove_macos_sidecar_files() {
    local root="$1"
    find "$root" -type f -name '*:com.apple.*' -delete
}

write_bundled_plugins_marketplace() {
    local source="$1"
    local destination="$2"
    local include_browser="$3"
    local include_computer_use="$4"

    node - "$source" "$destination" "$include_browser" "$include_computer_use" <<'NODE'
const fs = require("fs");
const path = require("path");

const sourcePath = process.argv[2];
const destinationPath = process.argv[3];
const includeBrowser = process.argv[4] === "1";
const includeComputerUse = process.argv[5] === "1";
const marketplace = JSON.parse(fs.readFileSync(sourcePath, "utf8"));
const sourcePlugins = marketplace.plugins || [];
const plugins = [];

if (includeBrowser) {
  const browserUse = sourcePlugins.find((plugin) => plugin.name === "browser-use");
  if (browserUse == null) {
    throw new Error("Bundled marketplace does not contain browser-use plugin");
  }
  plugins.push(browserUse);
}

if (includeComputerUse) {
  plugins.push({
    name: "computer-use",
    source: {
      source: "local",
      path: "./plugins/computer-use",
    },
    policy: {
      installation: "AVAILABLE",
      authentication: "ON_INSTALL",
    },
    category: "Productivity",
  });
}

marketplace.plugins = plugins;
fs.mkdirSync(path.dirname(destinationPath), { recursive: true });
fs.writeFileSync(destinationPath, `${JSON.stringify(marketplace, null, 2)}\n`);
NODE
}

install_bundled_plugin_resources() {
    local app_dir="$1"
    local upstream_resources="$app_dir/Contents/Resources"
    local source_marketplace="$upstream_resources/plugins/openai-bundled/.agents/plugins/marketplace.json"
    local source_plugin="$upstream_resources/plugins/openai-bundled/plugins/browser-use"
    local resources_dir="$INSTALL_DIR/resources"
    local bundled_plugins_dir="$resources_dir/plugins/openai-bundled"
    local include_browser=0
    local include_computer_use=0

    if [ ! -f "$source_marketplace" ]; then
        warn "Bundled plugin marketplace not found in upstream app; skipping bundled plugins"
        return 0
    fi

    mkdir -p "$bundled_plugins_dir/plugins" "$bundled_plugins_dir/.agents/plugins"

    if [ -d "$source_plugin" ]; then
        rm -rf "$bundled_plugins_dir/plugins/browser-use"
        cp -R "$source_plugin" "$bundled_plugins_dir/plugins/browser-use"
        remove_macos_sidecar_files "$bundled_plugins_dir/plugins/browser-use"
        include_browser=1
    else
        warn "Browser Use bundled plugin resources not found in upstream app; skipping Browser Use"
    fi

    if stage_linux_computer_use_plugin "$bundled_plugins_dir/plugins"; then
        include_computer_use=1
    else
        warn "Linux Computer Use plugin will be unavailable"
    fi

    if [ "$include_browser" -eq 0 ] && [ "$include_computer_use" -eq 0 ]; then
        warn "No Linux-safe bundled plugins were staged"
        return 0
    fi

    write_bundled_plugins_marketplace "$source_marketplace" "$bundled_plugins_dir/.agents/plugins/marketplace.json" "$include_browser" "$include_computer_use"

    install_linux_executable_resource "$upstream_resources/node" "$resources_dir/node" "node runtime" || true
    install_linux_executable_resource "$upstream_resources/node_repl" "$resources_dir/node_repl" "node_repl runtime" || true

    info "Linux-safe bundled plugins installed"
}

# ---- Create start script ----
create_start_script() {
    local quoted_app_id
    local quoted_app_display_name
    local quoted_webview_port
    quoted_app_id="$(shell_quote "$CODEX_APP_ID")"
    quoted_app_display_name="$(shell_quote "$CODEX_APP_DISPLAY_NAME")"
    quoted_webview_port="$(shell_quote "$CODEX_WEBVIEW_PORT")"

    cat > "$INSTALL_DIR/start.sh" << SCRIPT
#!/bin/bash
set -euo pipefail

CODEX_LINUX_APP_ID=$quoted_app_id
CODEX_LINUX_APP_DISPLAY_NAME=$quoted_app_display_name
CODEX_LINUX_WEBVIEW_PORT=\${CODEX_WEBVIEW_PORT:-$quoted_webview_port}
SCRIPT

    cat >> "$INSTALL_DIR/start.sh" << 'SCRIPT'
resolve_script_dir() {
    local source="${BASH_SOURCE[0]}"
    local dir

    while [ -L "$source" ]; do
        dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        case "$source" in
            /*) ;;
            *) source="$dir/$source" ;;
        esac
    done

    cd -P "$(dirname "$source")" && pwd
}

SCRIPT_DIR="$(resolve_script_dir)"
WEBVIEW_DIR="$SCRIPT_DIR/content/webview"
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/$CODEX_LINUX_APP_ID"
LOG_FILE="$LOG_DIR/launcher.log"
APP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$CODEX_LINUX_APP_ID"
APP_SETTINGS_FILE="$APP_CONFIG_DIR/settings.json"
APP_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$CODEX_LINUX_APP_ID"
APP_PID_FILE="$APP_STATE_DIR/app.pid"
WEBVIEW_PID_FILE="$APP_STATE_DIR/webview.pid"
LAUNCH_ACTION_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$APP_STATE_DIR}/$CODEX_LINUX_APP_ID"
LAUNCH_ACTION_SOCKET="$LAUNCH_ACTION_RUNTIME_DIR/launch-action.sock"
PACKAGED_RUNTIME_HELPER="$SCRIPT_DIR/.codex-linux/codex-packaged-runtime.sh"
APP_NOTIFICATION_ICON_NAME="$CODEX_LINUX_APP_ID"
APP_NOTIFICATION_ICON_BUNDLE="$SCRIPT_DIR/.codex-linux/$APP_NOTIFICATION_ICON_NAME.png"
APP_NOTIFICATION_ICON_SYSTEM="/usr/share/icons/hicolor/256x256/apps/$APP_NOTIFICATION_ICON_NAME.png"
APP_NOTIFICATION_ICON_REPO="$SCRIPT_DIR/../assets/codex.png"

case "$CODEX_LINUX_WEBVIEW_PORT" in
    ""|*[!0-9]*)
        echo "CODEX_WEBVIEW_PORT must be a TCP port number" >&2
        exit 1
        ;;
esac
if [ "$CODEX_LINUX_WEBVIEW_PORT" -lt 1 ] || [ "$CODEX_LINUX_WEBVIEW_PORT" -gt 65535 ]; then
    echo "CODEX_WEBVIEW_PORT must be between 1 and 65535" >&2
    exit 1
fi

WEBVIEW_ORIGIN="http://127.0.0.1:$CODEX_LINUX_WEBVIEW_PORT"

mkdir -p "$LOG_DIR" "$APP_CONFIG_DIR" "$APP_STATE_DIR" "$LAUNCH_ACTION_RUNTIME_DIR"
chmod 700 "$LAUNCH_ACTION_RUNTIME_DIR" 2>/dev/null || true
export CODEX_DESKTOP_LAUNCH_ACTION_SOCKET="$LAUNCH_ACTION_SOCKET"
STARTED_WEBVIEW_PID=""
ADOPTED_WEBVIEW_PID=""
ELECTRON_PID=""
RUNNING_APP_PID=""
WARM_START=0

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<HELP
Usage: ./start.sh [OPTIONS] [-- ELECTRON_FLAGS...]

Launches the $CODEX_LINUX_APP_DISPLAY_NAME app.

Options:
  -h, --help                  Show this help message and exit
  --new-chat                  Open the main window on a new chat
  --quick-chat                Open a projectless quick chat
  --prompt-chat               Show the compact prompt for a new chat
  --hotkey-window             Alias for --prompt-chat
  --safe-mode                 X11 + software rendering fallback
  --disable-gpu               Disable Electron GPU acceleration
  --enable-gpu                Re-enable Electron GPU acceleration
  --x11                       Force X11/XWayland
  --wayland                   Force native Wayland

Default launch keeps Electron GPU enabled and lets Electron choose the platform.
Extra flags are passed directly to Electron.

Logs: ${XDG_CACHE_HOME:-$HOME/.cache}/$CODEX_LINUX_APP_ID/launcher.log
HELP
    exit 0
fi

exec >>"$LOG_FILE" 2>&1

echo "[$(date -Is)] Starting $CODEX_LINUX_APP_DISPLAY_NAME launcher"

now_ms() {
    local value seconds nanos
    value="$(date +%s%N 2>/dev/null || true)"
    case "$value" in
        *N*|"") echo "$(($(date +%s) * 1000))" ;;
        *)
            seconds="${value:0:${#value}-9}"
            nanos="${value: -9}"
            echo "$((seconds * 1000 + 10#$nanos / 1000000))"
            ;;
    esac
}

LAUNCHER_START_MS="$(now_ms)"

log_phase() {
    local phase="$1"
    local elapsed_ms
    elapsed_ms="$(($(now_ms) - LAUNCHER_START_MS))"
    echo "[$(date -Is)] launcher_phase=$phase elapsedMs=$elapsed_ms"
}

import_graphical_env_entry() {
    local entry="$1"
    local name="${entry%%=*}"

    [ "$entry" != "$name" ] || return 0

    case "$name" in
        DISPLAY|WAYLAND_DISPLAY|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR|DESKTOP_SESSION|XAUTHORITY)
            if [ -z "${!name:-}" ]; then
                export "$entry"
            fi
            ;;
    esac
}

import_graphical_env_from_proc() {
    local pid="$1"
    local entry
    local found_display=0

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ -r "/proc/$pid/environ" ] || return 1

    while IFS= read -r -d '' entry; do
        case "$entry" in
            DISPLAY=*|WAYLAND_DISPLAY=*) found_display=1 ;;
        esac
        import_graphical_env_entry "$entry"
    done < "/proc/$pid/environ"

    [ "$found_display" -eq 1 ]
}

import_graphical_env_from_systemd_user() {
    local entry
    local found_display=0

    command -v systemctl >/dev/null 2>&1 || return 1

    while IFS= read -r entry; do
        case "$entry" in
            DISPLAY=*|WAYLAND_DISPLAY=*) found_display=1 ;;
        esac
        import_graphical_env_entry "$entry"
    done < <(systemctl --user show-environment 2>/dev/null || true)

    [ "$found_display" -eq 1 ]
}

discover_graphical_env_from_processes() {
    local status_file
    local pid
    local uid

    for status_file in /proc/[0-9]*/status; do
        [ -e "$status_file" ] || continue
        pid="${status_file#/proc/}"
        pid="${pid%/status}"
        uid="$(awk '/^Uid:/ {print $2}' "$status_file" 2>/dev/null || true)"
        [ "$uid" = "$(id -u)" ] || continue
        import_graphical_env_from_proc "$pid" && return 0
    done

    return 1
}

hydrate_graphical_session_env() {
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        return 0
    fi

    import_graphical_env_from_systemd_user && return 0
    discover_graphical_env_from_processes && return 0
    return 0
}

linux_setting_enabled() {
    local key="$1"
    local default_value="${2:-1}"

    python3 - "$APP_SETTINGS_FILE" "$key" "$default_value" <<'PY'
import json
import sys

settings_path, key, default_value = sys.argv[1:4]
enabled = default_value == "1"

try:
    with open(settings_path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if isinstance(data, dict) and key in data:
        value = data[key]
        if isinstance(value, bool):
            enabled = value
        elif isinstance(value, (int, float)):
            enabled = value != 0
        elif isinstance(value, str):
            enabled = value.strip().lower() not in {"0", "false", "no", "off"}
except FileNotFoundError:
    pass
except (OSError, json.JSONDecodeError):
    pass

raise SystemExit(0 if enabled else 1)
PY
}

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

resolve_browser_use_runtime_env() {
    if [ -z "${CODEX_ELECTRON_RESOURCES_PATH:-}" ]; then
        export CODEX_ELECTRON_RESOURCES_PATH="$SCRIPT_DIR/resources"
    fi

    if [ -z "${CODEX_BROWSER_USE_NODE_PATH:-}" ]; then
        if [ -x "$SCRIPT_DIR/resources/node" ]; then
            export CODEX_BROWSER_USE_NODE_PATH="$SCRIPT_DIR/resources/node"
        elif command -v node >/dev/null 2>&1; then
            CODEX_BROWSER_USE_NODE_PATH="$(command -v node)"
            export CODEX_BROWSER_USE_NODE_PATH
        fi
    fi

    if [ -z "${CODEX_NODE_REPL_PATH:-}" ]; then
        codex_runtime_node_repl="${XDG_CACHE_HOME:-$HOME/.cache}/codex-runtimes/codex-primary-runtime/dependencies/bin/node_repl"
        if [ -x "$SCRIPT_DIR/resources/node_repl" ]; then
            export CODEX_NODE_REPL_PATH="$SCRIPT_DIR/resources/node_repl"
        elif command -v node_repl >/dev/null 2>&1; then
            CODEX_NODE_REPL_PATH="$(command -v node_repl)"
            export CODEX_NODE_REPL_PATH
        elif [ -x "$codex_runtime_node_repl" ]; then
            export CODEX_NODE_REPL_PATH="$codex_runtime_node_repl"
        fi
    fi

    if [ -z "${CODEX_NODE_REPL_PATH:-}" ]; then
        echo "Browser Use node_repl runtime not found; in-app browser automation may be unavailable."
    fi
}

run_cli_preflight() {
    local allow_install_missing="${1:-0}"
    if ! command -v codex-update-manager >/dev/null 2>&1; then
        if [ "$allow_install_missing" = "1" ]; then
            return 1
        fi
        return 0
    fi

    local -a preflight_args=(
        cli-preflight
        --cli-path "$CODEX_CLI_PATH"
        --print-path
    )
    if [ "$allow_install_missing" = "1" ]; then
        preflight_args+=(--allow-install-missing)
    fi

    local refreshed_path=""
    if ! refreshed_path="$(codex-update-manager "${preflight_args[@]}")"; then
        if [ "$allow_install_missing" = "1" ]; then
            return 1
        fi
        notify_error "Codex CLI prelaunch check failed. Continuing with the current CLI state. Check the launcher and updater logs if Codex Desktop misbehaves."
        return 0
    fi

    if [ -n "$refreshed_path" ]; then
        CODEX_CLI_PATH="$refreshed_path"
        export CODEX_CLI_PATH
    fi
}

run_cli_preflight_background() {
    if ! command -v codex-update-manager >/dev/null 2>&1; then
        return 0
    fi

    (
        if ! codex-update-manager cli-preflight --cli-path "$CODEX_CLI_PATH" --print-path >/dev/null 2>&1; then
            echo "Codex CLI background preflight failed. Continuing with the current CLI."
        fi
    ) &
}

is_interactive_terminal() {
    [ -t 0 ] && [ -t 1 ]
}

run_gui_cli_prompt() {
    if ! command -v codex-update-manager >/dev/null 2>&1; then
        return 1
    fi

    local refreshed_path=""
    if ! refreshed_path="$(codex-update-manager prompt-install-cli --cli-path "$CODEX_CLI_PATH" --print-path)"; then
        return 1
    fi

    if [ -n "$refreshed_path" ]; then
        CODEX_CLI_PATH="$refreshed_path"
        export CODEX_CLI_PATH
    fi

    return 0
}

prompt_install_missing_cli() {
    if ! is_interactive_terminal; then
        return 1
    fi

    if ! command -v codex-update-manager >/dev/null 2>&1; then
        return 1
    fi

    local reply=""
    printf 'Codex CLI is not installed. Install it now? [Y/n] '
    if ! read -r reply; then
        return 1
    fi

    case "$reply" in
        ""|y|Y|yes|YES|Yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_notification_icon() {
    local candidate
    for candidate in \
        "$APP_NOTIFICATION_ICON_BUNDLE" \
        "$APP_NOTIFICATION_ICON_SYSTEM" \
        "$APP_NOTIFICATION_ICON_REPO"
    do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    echo "$APP_NOTIFICATION_ICON_NAME"
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
    local icon
    icon="$(resolve_notification_icon)"
    echo "$message"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send \
            -a "$CODEX_LINUX_APP_DISPLAY_NAME" \
            -i "$icon" \
            -h "string:desktop-entry:$CODEX_LINUX_APP_ID" \
            "$CODEX_LINUX_APP_DISPLAY_NAME" \
            "$message"
    fi
}

canonical_path() {
    readlink -f "$1" 2>/dev/null || echo "$1"
}

pid_is_current_user() {
    local pid="$1"
    local uid

    uid="$(awk '/^Uid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)"
    [ "$uid" = "$(id -u)" ]
}

pid_is_electron_helper() {
    local pid="$1"
    [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -q '^--type='
}

pid_matches_executable() {
    local pid="$1"
    local expected="$2"
    local actual

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ -d "/proc/$pid" ] || return 1
    pid_is_current_user "$pid" || return 1
    actual="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    [ "$actual" = "$(canonical_path "$expected")" ] || return 1
    ! pid_is_electron_helper "$pid"
}

find_running_app_pid() {
    local pid

    if [ -f "$APP_PID_FILE" ]; then
        pid="$(cat "$APP_PID_FILE" 2>/dev/null || true)"
        if pid_matches_executable "$pid" "$SCRIPT_DIR/electron"; then
            echo "$pid"
            return 0
        fi
    fi

    local proc_exe
    for proc_exe in /proc/[0-9]*/exe; do
        [ -e "$proc_exe" ] || continue
        pid="${proc_exe#/proc/}"
        pid="${pid%/exe}"
        if pid_matches_executable "$pid" "$SCRIPT_DIR/electron"; then
            echo "$pid"
            return 0
        fi
    done

    return 1
}

running_app_is_active() {
    [ -n "${RUNNING_APP_PID:-}" ] && pid_matches_executable "$RUNNING_APP_PID" "$SCRIPT_DIR/electron"
}

using_second_instance_handoff() {
    [ "$WARM_START" -eq 0 ] && running_app_is_active
}

needs_cold_start() {
    [ "$WARM_START" -eq 0 ] && ! using_second_instance_handoff
}

detect_warm_start() {
    if RUNNING_APP_PID="$(find_running_app_pid)"; then
        echo "$RUNNING_APP_PID" > "$APP_PID_FILE"
        if ! linux_setting_enabled "codex-linux-warm-start-enabled" 1; then
            WARM_START=0
            echo "Warm-start handoff disabled by $APP_SETTINGS_FILE"
            echo "Detected running Codex Desktop pid=$RUNNING_APP_PID; preserving liveness marker for second-instance handoff"
            return 0
        fi

        WARM_START=1
        echo "Detected running Codex Desktop pid=$RUNNING_APP_PID; using warm-start handoff"
        return 0
    fi

    if ! linux_setting_enabled "codex-linux-warm-start-enabled" 1; then
        WARM_START=0
        echo "Warm-start handoff disabled by $APP_SETTINGS_FILE"
    fi
}

send_warm_start_launch_action() {
    [ "$WARM_START" -eq 1 ] || return 1
    [ -S "$LAUNCH_ACTION_SOCKET" ] || return 1

    python3 - "$LAUNCH_ACTION_SOCKET" "$@" <<'PY'
import json
import socket
import sys

socket_path = sys.argv[1]
argv = sys.argv[2:]
payload = json.dumps({"argv": argv}, separators=(",", ":")).encode("utf-8") + b"\n"

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(1.0)
try:
    client.connect(socket_path)
    client.sendall(payload)
finally:
    client.close()
PY
}

wait_for_webview_server() {
    echo "Waiting for webview server on :$CODEX_LINUX_WEBVIEW_PORT"

    local attempt
    for attempt in $(seq 1 50); do
        if python3 - "$CODEX_LINUX_WEBVIEW_PORT" <<'PY' 2>/dev/null; then
import socket
import sys

port = int(sys.argv[1])
s = socket.socket()
s.settimeout(0.5)
s.connect(("127.0.0.1", port))
s.close()
PY
            echo "Webview server is ready"
            return 0
        fi
        sleep 0.1
    done

    return 1
}

verify_webview_origin() {
    local url="$1"

    python3 - "$url" <<'PY'
import sys
import urllib.request

url = sys.argv[1]
required_markers = ("<title>Codex</title>", "startup-loader")

with urllib.request.urlopen(url, timeout=2) as response:
    body = response.read(8192).decode("utf-8", "ignore")

missing = [marker for marker in required_markers if marker not in body]
if missing:
    raise SystemExit(
        f"Webview origin validation failed for {url}; missing markers: {', '.join(missing)}"
    )
PY
}

pid_is_webview_server() {
    local pid="$1"
    local cmdline
    local cwd

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ -d "/proc/$pid" ] || return 1
    pid_is_current_user "$pid" || return 1
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    [[ "$cmdline" == *"http.server $CODEX_LINUX_WEBVIEW_PORT"* ]] || return 1
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    [ "$cwd" = "$(canonical_path "$WEBVIEW_DIR")" ]
}

stop_owned_webview_server() {
    local pid=""

    if [ -f "$WEBVIEW_PID_FILE" ]; then
        pid="$(cat "$WEBVIEW_PID_FILE" 2>/dev/null || true)"
    fi

    if running_app_is_active && [ -n "$pid" ] && pid_is_webview_server "$pid"; then
        echo "Preserving webview server pid=$pid owned by running Codex Desktop pid=$RUNNING_APP_PID"
        return 0
    fi

    if [ -n "$pid" ] && pid_is_webview_server "$pid"; then
        echo "Stopping owned webview server pid=$pid"
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.05
        done
    fi

    rm -f "$WEBVIEW_PID_FILE"
}

owned_webview_server_pid() {
    local pid=""

    if [ -f "$WEBVIEW_PID_FILE" ]; then
        pid="$(cat "$WEBVIEW_PID_FILE" 2>/dev/null || true)"
    fi

    if [ -n "$pid" ] && pid_is_webview_server "$pid"; then
        echo "$pid"
        return 0
    fi

    if [ -n "$pid" ]; then
        rm -f "$WEBVIEW_PID_FILE"
    fi

    return 1
}

discover_webview_server_pid() {
    local proc_cmdline
    local pid

    for proc_cmdline in /proc/[0-9]*/cmdline; do
        [ -e "$proc_cmdline" ] || continue
        pid="${proc_cmdline#/proc/}"
        pid="${pid%/cmdline}"
        if pid_is_webview_server "$pid"; then
            echo "$pid"
            return 0
        fi
    done

    return 1
}

adopt_existing_webview_server() {
    local pid

    if pid="$(owned_webview_server_pid)"; then
        if running_app_is_active; then
            ADOPTED_WEBVIEW_PID="$pid"
            echo "Reusing webview server pid=$pid owned by running Codex Desktop pid=$RUNNING_APP_PID"
        else
            STARTED_WEBVIEW_PID="$pid"
        fi
        return 0
    fi

    if pid="$(discover_webview_server_pid)"; then
        echo "$pid" > "$WEBVIEW_PID_FILE"
        if running_app_is_active; then
            ADOPTED_WEBVIEW_PID="$pid"
            echo "Reusing webview server pid=$pid owned by running Codex Desktop pid=$RUNNING_APP_PID"
        else
            STARTED_WEBVIEW_PID="$pid"
            echo "Adopted existing webview server pid=$pid dir=$WEBVIEW_DIR"
        fi
        return 0
    fi

    return 1
}

ensure_webview_server() {
    if [ ! -d "$WEBVIEW_DIR" ] || [ ! "$(ls -A "$WEBVIEW_DIR" 2>/dev/null)" ]; then
        return 0
    fi

    if adopt_existing_webview_server; then
        if verify_webview_origin "$WEBVIEW_ORIGIN/index.html" >/dev/null 2>&1; then
            echo "Reusing existing verified webview server on :$CODEX_LINUX_WEBVIEW_PORT"
            log_phase "webview_reused"
            return 0
        fi

        if running_app_is_active; then
            notify_error "Codex Desktop webview server is already running for pid $RUNNING_APP_PID, but origin validation failed. Keeping the live app untouched."
            exit 1
        fi
    fi

    if verify_webview_origin "$WEBVIEW_ORIGIN/index.html" >/dev/null 2>&1; then
        notify_error "$CODEX_LINUX_APP_DISPLAY_NAME webview port $CODEX_LINUX_WEBVIEW_PORT is already serving Codex content, but it is not owned by this launcher. Stop the other webview server and try again."
        exit 1
    fi

    stop_owned_webview_server

    cd "$WEBVIEW_DIR"
    python3 -m http.server "$CODEX_LINUX_WEBVIEW_PORT" --bind 127.0.0.1 &
    STARTED_WEBVIEW_PID=$!
    echo "$STARTED_WEBVIEW_PID" > "$WEBVIEW_PID_FILE"

    echo "Started webview server pid=$STARTED_WEBVIEW_PID dir=$WEBVIEW_DIR"

    if ! wait_for_webview_server; then
        notify_error "$CODEX_LINUX_APP_DISPLAY_NAME webview server did not become ready on port $CODEX_LINUX_WEBVIEW_PORT. Check the launcher log for the embedded http.server output."
        exit 1
    fi

    if ! kill -0 "$STARTED_WEBVIEW_PID" 2>/dev/null; then
        notify_error "$CODEX_LINUX_APP_DISPLAY_NAME webview server exited before Electron launch. Another process may already be using port $CODEX_LINUX_WEBVIEW_PORT."
        exit 1
    fi

    if ! verify_webview_origin "$WEBVIEW_ORIGIN/index.html"; then
        notify_error "$CODEX_LINUX_APP_DISPLAY_NAME webview origin validation failed. Another process may be serving port $CODEX_LINUX_WEBVIEW_PORT or the extracted webview bundle is incomplete."
        exit 1
    fi

    echo "Webview origin verified."
    log_phase "webview_ready"
}

clear_stale_pid_file() {
    if [ ! -f "$APP_PID_FILE" ]; then
        return 0
    fi

    local pid=""
    pid="$(cat "$APP_PID_FILE" 2>/dev/null || true)"
    if [ -z "$pid" ] || ! pid_matches_executable "$pid" "$SCRIPT_DIR/electron"; then
        rm -f "$APP_PID_FILE"
    fi
}

set_electron_defaults() {
    ELECTRON_OZONE_PLATFORM=""
    ELECTRON_OZONE_HINT="auto"
    ELECTRON_GPU_ENABLED=1
    ELECTRON_ARGS=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --safe-mode)
                ELECTRON_OZONE_PLATFORM="x11"
                ELECTRON_OZONE_HINT=""
                ELECTRON_GPU_ENABLED=0
                ;;
            --disable-gpu)
                ELECTRON_GPU_ENABLED=0
                ;;
            --enable-gpu)
                ELECTRON_GPU_ENABLED=1
                ;;
            --x11)
                ELECTRON_OZONE_PLATFORM="x11"
                ELECTRON_OZONE_HINT=""
                ;;
            --wayland)
                ELECTRON_OZONE_PLATFORM="wayland"
                ELECTRON_OZONE_HINT=""
                ;;
            --ozone-platform=*)
                ELECTRON_OZONE_PLATFORM="${1#--ozone-platform=}"
                ELECTRON_OZONE_HINT=""
                ;;
            --ozone-platform-hint=*)
                ELECTRON_OZONE_HINT="${1#--ozone-platform-hint=}"
                ELECTRON_OZONE_PLATFORM=""
                ;;
            *)
                ELECTRON_ARGS+=("$1")
                ;;
        esac
        shift
    done
}

build_electron_launch_args() {
    ELECTRON_LAUNCH_ARGS=(
        --no-sandbox
        --class="$CODEX_LINUX_APP_ID"
        --app-id="$CODEX_LINUX_APP_ID"
        --disable-dev-shm-usage
        --disable-gpu-sandbox
        --disable-gpu-compositing
    )

    if [ "$CODEX_LINUX_APP_ID" != "codex-desktop" ]; then
        ELECTRON_LAUNCH_ARGS+=(--user-data-dir="${CODEX_ELECTRON_USER_DATA_DIR:-$APP_STATE_DIR/electron-user-data}")
    elif [ -n "${CODEX_ELECTRON_USER_DATA_DIR:-}" ]; then
        ELECTRON_LAUNCH_ARGS+=(--user-data-dir="$CODEX_ELECTRON_USER_DATA_DIR")
    fi

    if [ -n "$ELECTRON_OZONE_PLATFORM" ]; then
        ELECTRON_LAUNCH_ARGS+=(--ozone-platform="$ELECTRON_OZONE_PLATFORM")
    elif [ -n "$ELECTRON_OZONE_HINT" ]; then
        ELECTRON_LAUNCH_ARGS+=(--ozone-platform-hint="$ELECTRON_OZONE_HINT")
    fi

    if [ "$ELECTRON_GPU_ENABLED" != "1" ]; then
        ELECTRON_LAUNCH_ARGS+=(--disable-gpu --disable-features=Vulkan)
    fi

    if [ "${CODEX_FORCE_RENDERER_ACCESSIBILITY:-1}" = "1" ]; then
        ELECTRON_LAUNCH_ARGS+=(--force-renderer-accessibility)
    fi

    if [ "$ELECTRON_OZONE_PLATFORM" = "wayland" ]; then
        ELECTRON_LAUNCH_ARGS+=(--enable-features=WaylandWindowDecorations)
    fi
}

configure_side_by_side_app_env() {
    if [ "$CODEX_LINUX_APP_ID" = "codex-desktop" ]; then
        return 0
    fi

    XDG_CONFIG_HOME="${CODEX_XDG_CONFIG_HOME:-$APP_STATE_DIR/xdg-config}"
    CODEX_ELECTRON_USER_DATA_DIR="${CODEX_ELECTRON_USER_DATA_DIR:-$APP_STATE_DIR/electron-user-data}"
    export XDG_CONFIG_HOME CODEX_ELECTRON_USER_DATA_DIR
}

cleanup_launcher() {
    if [ -n "${ELECTRON_PID:-}" ] && [ -f "$APP_PID_FILE" ]; then
        local current_pid
        current_pid="$(cat "$APP_PID_FILE" 2>/dev/null || true)"
        if [ "$current_pid" = "$ELECTRON_PID" ]; then
            rm -f "$APP_PID_FILE"
        fi
    fi

    if [ -n "${STARTED_WEBVIEW_PID:-}" ] && pid_is_webview_server "$STARTED_WEBVIEW_PID"; then
        kill "$STARTED_WEBVIEW_PID" 2>/dev/null || true
        rm -f "$WEBVIEW_PID_FILE"
    fi
}

launch_electron() {
    cd "$SCRIPT_DIR"
    log_phase "electron_launch"

    set_electron_defaults "$@"
    build_electron_launch_args

    if [ "$WARM_START" -eq 1 ]; then
        echo "Electron warm-start handoff: pid=$RUNNING_APP_PID ozone_platform=${ELECTRON_OZONE_PLATFORM:-default} ozone_hint=${ELECTRON_OZONE_HINT:-none} gpu_enabled=$ELECTRON_GPU_ENABLED"
        "$SCRIPT_DIR/electron" "${ELECTRON_LAUNCH_ARGS[@]}" "${ELECTRON_ARGS[@]}"
        return $?
    fi

    echo "Electron launch mode: ozone_platform=${ELECTRON_OZONE_PLATFORM:-default} ozone_hint=${ELECTRON_OZONE_HINT:-none} gpu_enabled=$ELECTRON_GPU_ENABLED"
    "$SCRIPT_DIR/electron" "${ELECTRON_LAUNCH_ARGS[@]}" "${ELECTRON_ARGS[@]}" &
    ELECTRON_PID=$!
    if [ -n "${RUNNING_APP_PID:-}" ] && pid_matches_executable "$RUNNING_APP_PID" "$SCRIPT_DIR/electron"; then
        echo "Preserving Codex Desktop pid=$RUNNING_APP_PID liveness marker for second-instance handoff"
    else
        echo "$ELECTRON_PID" > "$APP_PID_FILE"
    fi
    log_phase "electron_spawned"

    set +e
    wait "$ELECTRON_PID"
    local status=$?
    set -e
    return "$status"
}

hydrate_graphical_session_env
configure_side_by_side_app_env
load_packaged_runtime_helper
clear_stale_pid_file
detect_warm_start
trap cleanup_launcher EXIT

if send_warm_start_launch_action "$@"; then
    echo "Sent launch args over warm-start IPC"
    log_phase "warm_start_ipc_sent"
    exit 0
elif [ "$WARM_START" -eq 1 ]; then
    echo "Warm-start IPC unavailable; falling back to Electron second-instance handoff"
fi

if using_second_instance_handoff; then
    echo "Detected running Codex Desktop pid=$RUNNING_APP_PID; using Electron second-instance handoff"
    log_phase "second_instance_handoff_ready"
elif needs_cold_start; then
    run_packaged_runtime_prelaunch
    log_phase "packaged_prelaunch"
    ensure_webview_server
else
    echo "Skipping packaged prelaunch and webview setup for warm start"
    log_phase "warm_start_ready"
fi

if needs_cold_start && [ -z "${CODEX_CLI_PATH:-}" ]; then
    CODEX_CLI_PATH="$(find_codex_cli || true)"
    export CODEX_CLI_PATH
    log_phase "cli_lookup"
fi
export CHROME_DESKTOP="${CHROME_DESKTOP:-$CODEX_LINUX_APP_ID.desktop}"
export ELECTRON_RENDERER_URL="${ELECTRON_RENDERER_URL:-$WEBVIEW_ORIGIN/}"

if needs_cold_start && [ -z "$CODEX_CLI_PATH" ]; then
    if is_interactive_terminal; then
        if prompt_install_missing_cli; then
            if ! run_cli_preflight 1; then
                notify_error "Codex CLI automatic installation failed. Install with: npm i -g @openai/codex or npm i -g --prefix ~/.local @openai/codex"
                exit 1
            fi
        fi
    elif ! run_gui_cli_prompt; then
        notify_error "Codex CLI not found. Install with: npm i -g @openai/codex or npm i -g --prefix ~/.local @openai/codex"
        exit 1
    fi
fi

if needs_cold_start && [ -z "$CODEX_CLI_PATH" ]; then
    notify_error "Codex CLI not found. Install with: npm i -g @openai/codex or npm i -g --prefix ~/.local @openai/codex"
    exit 1
fi

if needs_cold_start; then
    if [ "${CODEX_SYNC_CLI_PREFLIGHT:-0}" = "1" ]; then
        run_cli_preflight 0
        log_phase "cli_preflight_sync"
    else
        run_cli_preflight_background
        log_phase "cli_preflight_backgrounded"
    fi
fi

export_packaged_runtime_env
resolve_browser_use_runtime_env

echo "Using CODEX_CLI_PATH=${CODEX_CLI_PATH:-warm-start-skip}"

launch_electron "$@"
SCRIPT

    chmod +x "$INSTALL_DIR/start.sh"
    mkdir -p "$INSTALL_DIR/.codex-linux"
    if [ -f "$ICON_SOURCE" ]; then
        cp "$ICON_SOURCE" "$INSTALL_DIR/.codex-linux/$CODEX_APP_ID.png"
    else
        warn "Notification icon not found at $ICON_SOURCE"
    fi
    info "Start script created"
}

# ---- Main ----
main() {
    echo "============================================" >&2
    echo "  Codex Desktop for Linux — Installer"       >&2
    echo "============================================" >&2
    echo ""                                             >&2

    parse_args "$@"
    validate_app_identity
    check_deps
    assert_install_target_not_running
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

    detect_electron_version "$app_dir"
    patch_asar "$app_dir"
    download_electron
    extract_webview "$app_dir"
    install_app
    install_bundled_plugin_resources "$app_dir"
    create_start_script

    if ! command -v codex &>/dev/null; then
        warn "Codex CLI not found. Install it with: npm i -g @openai/codex or npm i -g --prefix ~/.local @openai/codex"
    fi

    echo ""                                             >&2
    echo "============================================" >&2
    info "Installation complete!"
    echo "  Run:  $INSTALL_DIR/start.sh"                >&2
    echo "============================================" >&2
}

if [ "${CODEX_INSTALLER_SOURCE_ONLY:-0}" != "1" ]; then
    main "$@"
fi
