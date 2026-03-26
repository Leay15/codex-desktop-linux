Name:           __PACKAGE_NAME__
Version:        __RPM_VERSION__
Release:        __RPM_RELEASE__%{?dist}
Summary:        Codex Desktop for Linux
License:        Proprietary
ExclusiveArch:  __ARCH__

Requires:       nodejs, npm, python3, p7zip, curl, unzip, gcc-c++, make
Requires:       alsa-lib, at-spi2-atk, atk, glib2, gtk3, libdrm
Requires:       nspr, nss, pango, libstdc++, libX11, libxcb
Requires:       libXcomposite, libXdamage, libXext, libXfixes, libxkbcommon, libXrandr
Requires:       mesa-libgbm

%description
Community-built Linux package for Codex Desktop generated from the macOS DMG.
Requires the Codex CLI to be available in PATH or configured via CODEX_CLI_PATH.
Local auto-updates rebuild a Linux package from the upstream Codex.dmg and therefore
require the local packaging toolchain listed in Requires.

%install
# Files are pre-staged in BUILDROOT by build-rpm.sh

%files
%defattr(-,root,root,-)
/opt/__PACKAGE_NAME__/
/usr/bin/__PACKAGE_NAME__
/usr/bin/codex-update-manager
/usr/lib/systemd/user/codex-update-manager.service
/usr/share/applications/__PACKAGE_NAME__.desktop
/usr/share/icons/hicolor/256x256/apps/__PACKAGE_NAME__.png

%post
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi

%preun
if [ $1 -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now codex-update-manager.service >/dev/null 2>&1 || true
fi

%changelog
* Wed Jan 01 2026 Codex Desktop Linux Maintainers <maintainers@codex-desktop-linux>
- Initial RPM package
