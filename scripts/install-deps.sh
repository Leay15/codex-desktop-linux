#!/bin/bash
# install-deps.sh — Install system dependencies for Codex Desktop Linux
# Supports: Debian/Ubuntu (apt), Fedora 41+ (dnf5), Fedora <41 (dnf), Arch (pacman)
# Also installs the Rust toolchain (cargo) via rustup when not already present.
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

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
        nodejs npm python3 \
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
        p7zip curl unzip \
        base-devel
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
    *)
        error "Unsupported package manager. Install manually:
  sudo apt install nodejs npm python3 p7zip-full curl unzip build-essential         # Debian/Ubuntu
  sudo dnf install nodejs npm python3 7zip curl unzip @development-tools            # Fedora 41+ (dnf5)
  sudo dnf install nodejs npm python3 p7zip p7zip-plugins curl unzip                # Fedora <41 (dnf)
    && sudo dnf groupinstall 'Development Tools'
  sudo pacman -S nodejs npm python p7zip curl unzip base-devel                      # Arch"
        ;;
esac

install_rust

info "All dependencies installed. You can now run: ./install.sh"
