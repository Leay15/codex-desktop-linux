#!/bin/bash
# install-deps.sh — Install system dependencies for Codex Desktop Linux
# Supports: Debian/Ubuntu (apt), Fedora 41+ (dnf5), Fedora <41 (dnf), Arch (pacman), openSUSE (zypper)
# Also installs the Rust toolchain (cargo) via rustup when not already present.
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
ARCH="$(uname -m)"
MIN_NODE_MAJOR=20
NODEJS_MAJOR="${NODEJS_MAJOR:-22}"

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Node.js compatibility
# ---------------------------------------------------------------------------
node_major() {
    command -v node &>/dev/null || return 1

    local version major
    version="$(node -v 2>/dev/null || true)"
    major="${version#v}"
    major="${major%%.*}"

    case "$major" in
        ''|*[!0-9]*) return 1 ;;
        *) printf '%s\n' "$major" ;;
    esac
}

has_compatible_nodejs() {
    local major
    major="$(node_major 2>/dev/null || true)"

    [ -n "$major" ] \
        && [ "$major" -ge "$MIN_NODE_MAJOR" ] \
        && command -v npm &>/dev/null \
        && command -v npx &>/dev/null
}

validate_nodejs_major() {
    case "$NODEJS_MAJOR" in
        ''|*[!0-9]*)
            error "NODEJS_MAJOR must be numeric, for example: NODEJS_MAJOR=22 bash scripts/install-deps.sh"
            ;;
    esac

    if [ "$NODEJS_MAJOR" -lt 22 ]; then
        error "NODEJS_MAJOR=$NODEJS_MAJOR is not supported for apt bootstrap. Use Node.js 22 or newer.
Existing user-managed Node.js 20 installations are still accepted by install.sh, but new bootstrap installs should use a maintained Node.js line."
    fi
}

apt_arch_for_nodesource() {
    local apt_arch
    apt_arch="$(dpkg --print-architecture)"

    case "$apt_arch" in
        amd64|arm64|armhf)
            printf '%s\n' "$apt_arch"
            ;;
        *)
            error "NodeSource apt packages are not available for architecture '$apt_arch'.
Install Node.js ${MIN_NODE_MAJOR}+ manually, then re-run this script."
            ;;
    esac
}

install_nodesource_nodejs() {
    validate_nodejs_major

    local apt_arch keyring source_list tmp_key
    apt_arch="$(apt_arch_for_nodesource)"
    keyring="/etc/apt/keyrings/nodesource.gpg"
    source_list="/etc/apt/sources.list.d/nodesource.list"
    tmp_key="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_key'" RETURN

    info "Installing Node.js ${NODEJS_MAJOR}.x from NodeSource"
    sudo apt-get install -y gnupg
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o "$tmp_key"
    gpg --dearmor < "$tmp_key" | sudo tee "$keyring" >/dev/null
    sudo chmod 0644 "$keyring"

    printf 'deb [arch=%s signed-by=%s] https://deb.nodesource.com/node_%s.x nodistro main\n' \
        "$apt_arch" "$keyring" "$NODEJS_MAJOR" \
        | sudo tee "$source_list" >/dev/null

    sudo apt-get update -qq
    sudo apt-get install -y nodejs
}

report_nodejs_toolchain() {
    info "Node.js toolchain available: node $(node -v), npm $(npm -v), npx $(npx -v)"
}

current_node_version_suffix() {
    if command -v node &>/dev/null; then
        printf ' but found %s' "$(node -v)"
    fi
}

ensure_nodejs_compatible() {
    local distro="$1"

    if has_compatible_nodejs; then
        report_nodejs_toolchain
        return
    fi

    if [ "$distro" != "apt" ]; then
        error "Node.js ${MIN_NODE_MAJOR}+ with npm and npx is required$(current_node_version_suffix).
Install a supported Node.js version for this distro, then re-run this script."
    fi

    warn "Node.js ${MIN_NODE_MAJOR}+ with npm and npx is required$(current_node_version_suffix)"
    install_nodesource_nodejs

    if has_compatible_nodejs; then
        report_nodejs_toolchain
        return
    fi

    error "NodeSource install completed, but Node.js ${MIN_NODE_MAJOR}+ with npm and npx is still unavailable.
Check apt output above or install Node.js ${MIN_NODE_MAJOR}+ manually."
}

# ---------------------------------------------------------------------------
# Distro detection
# ---------------------------------------------------------------------------
detect_distro() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf5 &>/dev/null; then
        echo "dnf5"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# Install helpers
# ---------------------------------------------------------------------------
install_apt() {
    info "Detected Debian/Ubuntu (apt)"
    sudo apt-get update -qq
    sudo apt-get install -y \
        ca-certificates python3 \
        p7zip-full curl unzip \
        build-essential
}

install_dnf5() {
    info "Detected Fedora 41+ (dnf5)"
    # dnf5: 7zip provides /usr/bin/7z; @development-tools is the group syntax
    sudo dnf install -y \
        nodejs npm python3 \
        7zip curl unzip \
        @development-tools
}

install_dnf() {
    info "Detected Fedora/RHEL (dnf)"
    # Older dnf: 7z comes from p7zip + p7zip-plugins
    sudo dnf install -y \
        nodejs npm python3 \
        p7zip p7zip-plugins curl unzip
    sudo dnf groupinstall -y 'Development Tools'
}

install_pacman() {
    info "Detected Arch Linux (pacman)"
    sudo pacman -S --needed --noconfirm \
        nodejs npm python \
        p7zip curl unzip zstd \
        base-devel
}

install_zypper() {
    info "Detected openSUSE (zypper)"
    sudo zypper --non-interactive install \
        nodejs-default npm-default python3 \
        p7zip-full curl unzip
    sudo zypper --non-interactive install -t pattern devel_basis
}

# ---------------------------------------------------------------------------
# 7zz bootstrap (modern 7-Zip for APFS DMG support)
# Pinned versions — prepend new entries as upstream releases them.
# ---------------------------------------------------------------------------
bootstrap_7zz() {
    # Already present and functional
    if command -v 7zz &>/dev/null && 7zz 2>&1 | grep -qm 1 "7-Zip"; then
        info "7zz already available ($(command -v 7zz))"
        return 0
    fi

    # System 7z is already new enough — skip
    if command -v 7z &>/dev/null && ! 7z 2>&1 | grep -m 1 "7-Zip" | grep -q "16.02"; then
        info "System 7z is already new enough; skipping 7zz bootstrap"
        return 0
    fi

    local sevenzip_arch
    case "$ARCH" in
        x86_64)  sevenzip_arch="x64"   ;;
        aarch64) sevenzip_arch="arm64"  ;;
        armv7l)  sevenzip_arch="arm"    ;;
        *)
            warn "Skipping 7zz bootstrap: unsupported architecture '$ARCH'"
            return 0
            ;;
    esac

    local install_dir="$HOME/.local/bin"
    if [ "${SEVENZIP_SYSTEM_INSTALL:-0}" = "1" ]; then
        install_dir="/usr/local/bin"
    fi

    # Try pinned versions newest-first with HEAD verification — no HTML parsing
    local -a versions=(2600 2500 2409)
    local version="" url="" candidate_url
    for candidate in "${versions[@]}"; do
        candidate_url="https://www.7-zip.org/a/7z${candidate}-linux-${sevenzip_arch}.tar.xz"
        if curl -fsI "$candidate_url" >/dev/null 2>&1; then
            version="$candidate"
            url="$candidate_url"
            break
        fi
    done

    if [ -z "$url" ]; then
        error "Could not find a known-good 7zz tarball for architecture '$ARCH'.
Tried versions: ${versions[*]}
Install 7zz manually from https://www.7-zip.org/download.html and ensure it is on your PATH."
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" EXIT

    info "Downloading 7zz ${version} from $url"
    curl -fL --progress-bar -o "$tmpdir/7z.tar.xz" "$url"
    tar -C "$tmpdir" -xf "$tmpdir/7z.tar.xz" 7zz

    if [ "$install_dir" = "/usr/local/bin" ]; then
        sudo install -d -m 755 "$install_dir"
        sudo install -m 755 "$tmpdir/7zz" "$install_dir/7zz"
    else
        mkdir -p "$install_dir"
        install -m 755 "$tmpdir/7zz" "$install_dir/7zz"
    fi

    info "Installed 7zz to $install_dir/7zz"

    if ! printf '%s\n' "$PATH" | tr ':' '\n' | grep -Fxq "$install_dir"; then
        warn "$install_dir is not on your PATH. Add it with:"
        warn "  export PATH=\"$install_dir:\$PATH\""
    fi
}

# ---------------------------------------------------------------------------
# Rust / cargo (via rustup — distro-independent)
# ---------------------------------------------------------------------------
install_rust() {
    # Already on PATH
    if command -v cargo &>/dev/null; then
        info "cargo already installed ($(cargo --version))"
        return
    fi

    # Installed by rustup but not yet sourced in this session
    if [ -x "$HOME/.cargo/bin/cargo" ]; then
        info "cargo found at ~/.cargo/bin — sourcing environment"
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
        return
    fi

    info "Installing Rust toolchain via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

    # Make cargo available in this shell session
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"

    info "Rust installed. Run 'source \$HOME/.cargo/env' or open a new terminal to use cargo."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
DISTRO="$(detect_distro)"

case "$DISTRO" in
    apt)     install_apt    ;;
    dnf5)    install_dnf5   ;;
    dnf)     install_dnf    ;;
    pacman)  install_pacman ;;
    zypper)  install_zypper ;;
    *)
        error "Unsupported package manager. Install manually:
  # Debian/Ubuntu: install Node.js 20+ with npm/npx from NodeSource, nvm, or another compatible source, then:
  sudo apt install python3 p7zip-full curl unzip build-essential                   # Debian/Ubuntu
  sudo dnf install nodejs npm python3 7zip curl unzip @development-tools            # Fedora 41+ (dnf5)
  sudo dnf install nodejs npm python3 p7zip p7zip-plugins curl unzip                # Fedora <41 (dnf)
    && sudo dnf groupinstall 'Development Tools'
  sudo pacman -S nodejs npm python p7zip curl unzip zstd base-devel                 # Arch
  sudo zypper install nodejs-default npm-default python3 p7zip-full curl unzip      # openSUSE
    && sudo zypper install -t pattern devel_basis"
        ;;
esac

ensure_nodejs_compatible "$DISTRO"
install_rust
bootstrap_7zz

info "All dependencies installed. You can now run: ./install.sh"
