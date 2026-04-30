#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

info() {
    echo "[smoke] $*" >&2
}

fail() {
    echo "[smoke][FAIL] $*" >&2
    exit 1
}

assert_file_exists() {
    local path="$1"
    [ -f "$path" ] || fail "Expected file to exist: $path"
}

assert_contains() {
    local path="$1"
    local pattern="$2"
    grep -q -- "$pattern" "$path" || fail "Expected '$pattern' in $path"
}

assert_not_contains() {
    local path="$1"
    local pattern="$2"
    if grep -q -- "$pattern" "$path"; then
        fail "Did not expect '$pattern' in $path"
    fi
}

assert_occurrence_count() {
    local path="$1"
    local pattern="$2"
    local expected="$3"
    local actual
    actual="$(grep -o -- "$pattern" "$path" | wc -l | tr -d ' ')"
    [ "$actual" = "$expected" ] || fail "Expected '$pattern' to appear $expected times in $path, found $actual"
}

make_fake_app() {
    local app_dir="$1"
    mkdir -p "$app_dir"
    cat > "$app_dir/start.sh" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
    chmod +x "$app_dir/start.sh"
}

make_stub_bin_dir() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
}

test_common_helper_sourcing() {
    info "Checking shared packaging helpers"
    local probe_file="$TMP_DIR/probe.txt"
    touch "$probe_file"

    # shellcheck disable=SC1091
    source "$REPO_DIR/scripts/lib/package-common.sh"
    ensure_file_exists "$probe_file" "probe file"
}

test_deb_builder_smoke() {
    info "Running Debian packaging smoke test"
    local workspace="$TMP_DIR/deb"
    local bin_dir="$workspace/bin"
    local app_dir="$workspace/app"
    local dist_dir="$workspace/dist"
    local pkg_root="$workspace/deb-root"
    local updater_bin="$workspace/codex-update-manager"

    mkdir -p "$workspace" "$dist_dir"
    make_stub_bin_dir "$bin_dir"
    make_fake_app "$app_dir"
    printf '#!/bin/bash\nexit 0\n' > "$updater_bin"
    chmod +x "$updater_bin"

    cat > "$bin_dir/dpkg" <<'SCRIPT'
#!/bin/bash
if [ "$1" = "--print-architecture" ]; then
    echo amd64
    exit 0
fi
exit 0
SCRIPT
    cat > "$bin_dir/dpkg-deb" <<'SCRIPT'
#!/bin/bash
output="${@: -1}"
mkdir -p "$(dirname "$output")"
touch "$output"
SCRIPT
    cat > "$bin_dir/cargo" <<'SCRIPT'
#!/bin/bash
echo "cargo should not be called when UPDATER_BINARY_SOURCE exists" >&2
exit 99
SCRIPT
    chmod +x "$bin_dir/dpkg" "$bin_dir/dpkg-deb" "$bin_dir/cargo"

    PATH="$bin_dir:$PATH" \
    APP_DIR_OVERRIDE="$app_dir" \
    PKG_ROOT_OVERRIDE="$pkg_root" \
    DIST_DIR_OVERRIDE="$dist_dir" \
    UPDATER_BINARY_SOURCE="$updater_bin" \
    PACKAGE_VERSION="2026.03.24.120000+deadbeef" \
    "$REPO_DIR/scripts/build-deb.sh"

    assert_file_exists "$dist_dir/codex-desktop_2026.03.24.120000+deadbeef_amd64.deb"
    assert_file_exists "$pkg_root/DEBIAN/prerm"
    assert_file_exists "$pkg_root/DEBIAN/postrm"
    assert_file_exists "$pkg_root/opt/codex-desktop/update-builder/scripts/lib/package-common.sh"
    assert_file_exists "$pkg_root/opt/codex-desktop/.codex-linux/codex-packaged-runtime.sh"
}

test_rpm_builder_smoke() {
    info "Running RPM packaging smoke test"
    local workspace="$TMP_DIR/rpm"
    local bin_dir="$workspace/bin"
    local app_dir="$workspace/app"
    local dist_dir="$workspace/dist"
    local updater_bin="$workspace/codex-update-manager"

    mkdir -p "$workspace" "$dist_dir"
    make_stub_bin_dir "$bin_dir"
    make_fake_app "$app_dir"
    printf '#!/bin/bash\nexit 0\n' > "$updater_bin"
    chmod +x "$updater_bin"

    cat > "$bin_dir/rpmbuild" <<'SCRIPT'
#!/bin/bash
rpmdir=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--define" ]; then
        case "$2" in
            _rpmdir\ *) rpmdir="${2#_rpmdir }" ;;
        esac
        shift 2
        continue
    fi
    shift
done
[ -n "$rpmdir" ] || exit 1
mkdir -p "$rpmdir/x86_64"
touch "$rpmdir/x86_64/codex-desktop-2026.03.24.120000-deadbeef.x86_64.rpm"
SCRIPT
    cat > "$bin_dir/cargo" <<'SCRIPT'
#!/bin/bash
echo "cargo should not be called when UPDATER_BINARY_SOURCE exists" >&2
exit 99
SCRIPT
    chmod +x "$bin_dir/rpmbuild" "$bin_dir/cargo"

    PATH="$bin_dir:$PATH" \
    APP_DIR_OVERRIDE="$app_dir" \
    DIST_DIR_OVERRIDE="$dist_dir" \
    UPDATER_BINARY_SOURCE="$updater_bin" \
    PACKAGE_VERSION="2026.03.24.120000+deadbeef" \
    "$REPO_DIR/scripts/build-rpm.sh"

    assert_file_exists "$dist_dir/codex-desktop-2026.03.24.120000-deadbeef.x86_64.rpm"
}

test_missing_input_failure() {
    info "Checking missing-input failure path"
    local workspace="$TMP_DIR/missing"
    local bin_dir="$workspace/bin"
    local rpm_app_dir="$workspace/rpm-app"
    local rpm_log="$workspace/rpm-missing-runtime.log"

    mkdir -p "$workspace"
    make_stub_bin_dir "$bin_dir"
    make_fake_app "$rpm_app_dir"
    cat > "$bin_dir/dpkg" <<'SCRIPT'
#!/bin/bash
echo amd64
SCRIPT
    cat > "$bin_dir/dpkg-deb" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
    chmod +x "$bin_dir/dpkg" "$bin_dir/dpkg-deb"

    if PATH="$bin_dir:$PATH" APP_DIR_OVERRIDE="$workspace/does-not-exist" PKG_ROOT_OVERRIDE="$workspace/deb-root" "$REPO_DIR/scripts/build-deb.sh" >/dev/null 2>&1; then
        fail "build-deb.sh should fail when APP_DIR is missing"
    fi

    if APP_DIR_OVERRIDE="$rpm_app_dir" PACKAGED_RUNTIME_SOURCE="$workspace/does-not-exist.sh" "$REPO_DIR/scripts/build-rpm.sh" >"$rpm_log" 2>&1; then
        fail "build-rpm.sh should fail when PACKAGED_RUNTIME_SOURCE is missing"
    fi
    assert_contains "$rpm_log" "Missing packaged launcher runtime helper"
}

test_make_build_app_uses_installer_download_flow_by_default() {
    info "Checking make build-app default DMG behavior"
    local workspace="$TMP_DIR/make-build-app"
    local install_log="$workspace/install-args.log"

    mkdir -p "$workspace"

    cat > "$workspace/install.sh" <<'SCRIPT'
#!/bin/bash
set -eu
printf '%s\n' "$#" > "$TEST_INSTALL_LOG"
if [ "$#" -gt 0 ]; then
    printf '%s\n' "$1" >> "$TEST_INSTALL_LOG"
fi
SCRIPT
    chmod +x "$workspace/install.sh"

    TEST_INSTALL_LOG="$install_log" make -f "$REPO_DIR/Makefile" -C "$workspace" build-app >/dev/null

    assert_file_exists "$install_log"
    first_line="$(sed -n '1p' "$install_log")"
    second_line="$(sed -n '2p' "$install_log")"
    [ "$first_line" = "1" ] || fail "Expected make build-app to call install.sh with a single default argument slot, got: $(cat "$install_log")"
    [ -z "$second_line" ] || fail "Expected make build-app default DMG argument to be empty so install.sh falls back to reuse/download, got: $(cat "$install_log")"
}

test_installer_detects_electron_version_from_plist() {
    info "Checking Electron version detection from app metadata"
    local workspace="$TMP_DIR/electron-version"
    local app_dir="$workspace/Codex.app"
    local plist_dir="$app_dir/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources"
    local output_log="$workspace/output.log"

    mkdir -p "$plist_dir"
    cat > "$plist_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleVersion</key>
    <string>42.5.7</string>
</dict>
</plist>
PLIST

    CODEX_INSTALLER_SOURCE_ONLY=1 bash -c \
        'source "$1"; detect_electron_version "$2"; printf "%s\n" "$ELECTRON_VERSION"' \
        _ "$REPO_DIR/install.sh" "$app_dir" >"$output_log" 2>&1

    assert_contains "$output_log" "Detected Electron version from DMG: 42.5.7"
    [ "$(tail -n 1 "$output_log")" = "42.5.7" ] || fail "Expected detected Electron version 42.5.7, got: $(cat "$output_log")"
}

test_installer_keeps_electron_fallback_for_bad_metadata() {
    info "Checking Electron version fallback for malformed metadata"
    local workspace="$TMP_DIR/electron-version-fallback"
    local app_dir="$workspace/Codex.app"
    local plist_dir="$app_dir/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources"
    local output_log="$workspace/output.log"

    mkdir -p "$plist_dir"
    cat > "$plist_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleVersion</key>
    <string>not-a-version</string>
</dict>
</plist>
PLIST

    CODEX_INSTALLER_SOURCE_ONLY=1 bash -c \
        'source "$1"; detect_electron_version "$2"; printf "%s\n" "$ELECTRON_VERSION"' \
        _ "$REPO_DIR/install.sh" "$app_dir" >"$output_log" 2>&1

    assert_contains "$output_log" "Ignoring invalid Electron version from DMG: not-a-version"
    assert_contains "$output_log" "Could not auto-detect Electron version; using fallback 41.3.0"
    [ "$(tail -n 1 "$output_log")" = "41.3.0" ] || fail "Expected fallback Electron version 41.3.0, got: $(cat "$output_log")"
}

test_launcher_template_sanity() {
    info "Checking launcher template markers"
    assert_contains "$REPO_DIR/install.sh" "python3 -m http.server 5175 --bind 127.0.0.1"
    assert_contains "$REPO_DIR/install.sh" "WEBVIEW_PID_FILE"
    assert_contains "$REPO_DIR/install.sh" "owned_webview_server_pid"
    assert_contains "$REPO_DIR/install.sh" "discover_webview_server_pid"
    assert_contains "$REPO_DIR/install.sh" "Adopted existing webview server"
    assert_contains "$REPO_DIR/install.sh" "detect_warm_start"
    assert_contains "$REPO_DIR/install.sh" "launcher_phase"
    assert_contains "$REPO_DIR/install.sh" "CODEX_SYNC_CLI_PREFLIGHT"
    assert_contains "$REPO_DIR/install.sh" "wait_for_webview_server"
    assert_contains "$REPO_DIR/install.sh" "verify_webview_origin"
    assert_contains "$REPO_DIR/install.sh" "Webview origin verified."
    assert_not_contains "$REPO_DIR/install.sh" "pkill -f \"http.server 5175\""
    assert_contains "$REPO_DIR/install.sh" "--app-id=codex-desktop"
    assert_contains "$REPO_DIR/install.sh" "--ozone-platform-hint=auto"
    assert_contains "$REPO_DIR/install.sh" "--disable-gpu-sandbox"
    assert_contains "$REPO_DIR/install.sh" "PACKAGED_RUNTIME_HELPER"
    assert_contains "$REPO_DIR/install.sh" "prompt_install_missing_cli"
    assert_contains "$REPO_DIR/install.sh" "Install it now? \\[Y/n\\]"
    assert_contains "$REPO_DIR/install.sh" "is_interactive_terminal"
    assert_contains "$REPO_DIR/packaging/linux/codex-packaged-runtime.sh" "CHROME_DESKTOP"
    assert_contains "$REPO_DIR/packaging/linux/codex-packaged-runtime.sh" "codex-update-manager-launch-check"
    assert_contains "$REPO_DIR/packaging/linux/codex-packaged-runtime.sh" "codex-update-manager check-now --if-stale"
    assert_not_contains "$REPO_DIR/packaging/linux/codex-packaged-runtime.sh" "restart codex-update-manager.service"
    assert_contains "$REPO_DIR/scripts/install-deps.sh" 'NODEJS_MAJOR="${NODEJS_MAJOR:-22}"'
    assert_contains "$REPO_DIR/scripts/install-deps.sh" "apt_nodejs_candidate_major"
    assert_contains "$REPO_DIR/scripts/install-deps.sh" "Installing distro Node.js/npm candidate"
    assert_contains "$REPO_DIR/scripts/install-deps.sh" "/etc/apt/keyrings/nodesource.gpg"
    assert_contains "$REPO_DIR/scripts/install-deps.sh" "signed-by="
    assert_contains "$REPO_DIR/scripts/install-deps.sh" "https://deb.nodesource.com/node_"
    assert_contains "$REPO_DIR/packaging/linux/control" "nodejs (>= 20)"
    assert_contains "$REPO_DIR/packaging/linux/codex-desktop.spec" "nodejs >= 20"
    assert_contains "$REPO_DIR/packaging/linux/PKGBUILD.template" "nodejs>=20"
    assert_contains "$REPO_DIR/scripts/build-rpm.sh" "stage_common_package_files"
    assert_contains "$REPO_DIR/scripts/build-rpm.sh" "PACKAGED_RUNTIME_SOURCE"
    assert_contains "$REPO_DIR/packaging/linux/codex-desktop.desktop" "BAMF_DESKTOP_FILE_HINT"
}

make_fake_extracted_asar() {
    local root="$1"
    local bundle_body="$2"
    local settings_body="${3:-}"
    local index_body="${4:-}"

    mkdir -p "$root/webview/assets" "$root/.vite/build"
    printf 'png' > "$root/webview/assets/app-test.png"
    if [ -n "$settings_body" ]; then
        printf '%s\n' "$settings_body" > "$root/webview/assets/general-settings-test.js"
    fi
    if [ -n "$index_body" ]; then
        printf '%s\n' "$index_body" > "$root/webview/assets/index-test.js"
    fi
    cat > "$root/package.json" <<'JSON'
{}
JSON
    printf '%s\n' "$bundle_body" > "$root/.vite/build/main-test.js"
}

test_linux_file_manager_patch_smoke() {
    info "Checking Linux file manager patch behavior"
    local workspace="$TMP_DIR/file-manager-patch"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"

    mkdir -p "$workspace"
    make_fake_extracted_asar "$extracted" 'let D={removeMenu(){},setMenuBarVisibility(){},setIcon(){},once(){}};let n=require(`electron`),t=require(`node:path`),a=require(`node:fs`);...process.platform===`win32`?{autoHideMenuBar:!0}:{},process.platform===`win32`&&D.removeMenu(),foo)}),D.once(`ready-to-show`,()=>{var sa=Mi({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>ai(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:ca,args:e=>ai(e),open:async({path:e})=>la(e)}});function ca(){let e=1;return e}async function la(e){let t=ua(e);if(t&&(0,a.statSync)(t).isFile()){n.shell.showItemInFolder(t);return}let r=t??e,i=await n.shell.openPath(r);if(i)throw Error(i)}function ua(e){return e}var Ua=Mi({id:`systemDefault`,label:`System Default App`,icon:`apps/file-explorer.png`,kind:`systemDefault`,hidden:!0,darwin:{icon:`apps/finder.png`,detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},win32:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},linux:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)}});async function Wa(e){return e}'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$extracted/.vite/build/main-test.js" 'detect:()=>`linux-file-manager`'
    assert_contains "$extracted/.vite/build/main-test.js" 'linux:{label:`File Manager`'
    assert_contains "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&D.setMenuBarVisibility(!1),'
    assert_contains "$extracted/.vite/build/main-test.js" '&&D.setIcon('
    assert_not_contains "$output_log" 'Failed to apply Linux File Manager Patch'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_not_contains "$output_log" 'Failed to apply Linux File Manager Patch'
}

test_linux_translucent_sidebar_default_patch_smoke() {
    info "Checking Linux translucent sidebar default patch behavior"
    local workspace="$TMP_DIR/translucent-sidebar-patch"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"

    mkdir -p "$workspace"
    make_fake_extracted_asar \
        "$extracted" \
        'let D={removeMenu(){},setMenuBarVisibility(){},setIcon(){},once(){}};let n=require(`electron`),t=require(`node:path`),a=require(`node:fs`);...process.platform===`win32`?{autoHideMenuBar:!0}:{},process.platform===`win32`&&D.removeMenu(),foo)}),D.once(`ready-to-show`,()=>{var sa=Mi({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>ai(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:ca,args:e=>ai(e),open:async({path:e})=>la(e)}});function ca(){let e=1;return e}async function la(e){let t=ua(e);if(t&&(0,a.statSync)(t).isFile()){n.shell.showItemInFolder(t);return}let r=t??e,i=await n.shell.openPath(r);if(i)throw Error(i)}function ua(e){return e}var Ua=Mi({id:`systemDefault`,label:`System Default App`,icon:`apps/file-explorer.png`,kind:`systemDefault`,hidden:!0,darwin:{icon:`apps/finder.png`,detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},win32:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},linux:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)}});async function Wa(e){return e}' \
        'function settings(){let d=ot(r,e),f=at(e),p={codeThemeId:tt(a,e).id,theme:d},x=`settings.general.appearance.chromeTheme.translucentSidebar`;return {p,x}}' \
        'function runtime(){let o=`light`,a=`electron`,l=null,f=null,C=fl(l,`light`),w=fl(f,`dark`);let T=o===`light`?C:w,E;if(T.opaqueWindows&&!XZ()){document.body.classList.add(`electron-opaque`);return E}return E}'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$extracted/webview/assets/general-settings-test.js" 'navigator.userAgent.includes(`Linux`)&&r?.opaqueWindows==null&&(d={...d,opaqueWindows:!0})'
    assert_contains "$extracted/webview/assets/index-test.js" 'document.documentElement.dataset.codexOs===`linux`&&((o===`light`?l:f)?.opaqueWindows==null&&(T={...T,opaqueWindows:!0}))'
    assert_occurrence_count "$extracted/webview/assets/general-settings-test.js" 'navigator.userAgent.includes(`Linux`)' '1'
    assert_occurrence_count "$extracted/webview/assets/index-test.js" 'dataset.codexOs===`linux`' '1'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_occurrence_count "$extracted/webview/assets/general-settings-test.js" 'navigator.userAgent.includes(`Linux`)' '1'
    assert_occurrence_count "$extracted/webview/assets/index-test.js" 'dataset.codexOs===`linux`' '1'
}

test_linux_tray_patch_smoke() {
    info "Checking Linux tray patch behavior"
    local workspace="$TMP_DIR/tray-patch"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"
    local bundle_body

    mkdir -p "$workspace"
    bundle_body="$(cat <<'JS'
let D={removeMenu(){},setMenuBarVisibility(){},setIcon(){},once(){}};
let n=require(`electron`),i=require(`node:path`),a=require(`node:fs`);
let t={join(){},C:{Prod:`prod`},A(){}};
let k={hide(){},isDestroyed(){return false}};
let f=`local`;
...process.platform===`win32`?{autoHideMenuBar:!0}:{},process.platform===`win32`&&D.removeMenu(),foo)}),D.once(`ready-to-show`,()=>{
var sa=Mi({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>ai(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:ca,args:e=>ai(e),open:async({path:e})=>la(e)}});
function ca(){let e=1;return e}
async function la(e){let t=ua(e);if(t&&(0,a.statSync)(t).isFile()){n.shell.showItemInFolder(t);return}let r=t??e,i=await n.shell.openPath(r);if(i)throw Error(i)}
function ua(e){return e}
var Ua=Mi({id:`systemDefault`,label:`System Default App`,icon:`apps/file-explorer.png`,kind:`systemDefault`,hidden:!0,darwin:{icon:`apps/finder.png`,detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},win32:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},linux:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)}});
async function Wa(e){return e}
function Nw(e,n){return `icon`}
async function Hw(e){return process.platform!==`win32`&&process.platform!==`darwin`?null:(zw=!0,Lw??Rw??(Rw=(async()=>{let r=await Ww(e.buildFlavor,e.repoRoot),i=new n.Tray(r.defaultIcon);return i})()))}
async function Ww(e,t){if(process.platform===`darwin`){return null}let r=process.platform===`win32`?`.ico`:`.png`,a=Nw(e,process.platform),o=[...n.app.isPackaged?[(0,i.join)(process.resourcesPath,`${a}${r}`)]:[],(0,i.join)(t,`electron`,`src`,`icons`,`${a}${r}`)];for(let e of o){let t=n.nativeImage.createFromPath(e);if(!t.isEmpty())return{defaultIcon:t,chronicleRunningIcon:null}}return{defaultIcon:await n.app.getFileIcon(process.execPath,{size:process.platform===`win32`?`small`:`normal`}),chronicleRunningIcon:null}}
var pb=class{trayMenuThreads={runningThreads:[],unreadThreads:[],pinnedThreads:[],recentThreads:[],usageLimits:[]};constructor(){this.tray={on(){},setContextMenu(){},popUpContextMenu(){}};this.onTrayButtonClick=()=>{};this.tray.on(`click`,()=>{this.onTrayButtonClick()}),this.tray.on(`right-click`,()=>{this.openNativeTrayMenu()})}async handleMessage(e){switch(e.type){case`tray-menu-threads-changed`:this.trayMenuThreads=e.trayMenuThreads;return}}openNativeTrayMenu(){this.updateChronicleTrayIcon();let e=n.Menu.buildFromTemplate(this.getNativeTrayMenuItems());e.once(`menu-will-show`,()=>{this.isNativeTrayMenuOpen=!0}),e.once(`menu-will-close`,()=>{this.isNativeTrayMenuOpen=!1,this.handleNativeTrayMenuClosed()}),this.tray.popUpContextMenu(e)}updateChronicleTrayIcon(){}getNativeTrayMenuItems(){return[]}}
v&&k.on(`close`,e=>{this.persistPrimaryWindowBounds(k,f);let t=this.getPrimaryWindows(f).some(e=>e!==k);if(process.platform===`win32`&&f===`local`&&!this.isAppQuitting&&this.options.canHideLastLocalWindowToTray?.()===!0&&!t){e.preventDefault(),k.hide();return}if(process.platform===`darwin`&&!this.isAppQuitting&&!t){e.preventDefault(),k.hide()}});
let E=process.platform===`win32`;
let oe=async()=>{};
let se=async e=>{};
E&&oe();let ce=Hr({});
JS
)"
    make_fake_extracted_asar "$extracted" "$bundle_body"

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$extracted/.vite/build/main-test.js" 'process.platform!==`win32`&&process.platform!==`darwin`&&process.platform!==`linux`?null:'
    assert_contains "$extracted/.vite/build/main-test.js" 'nativeImage.createFromPath(process.resourcesPath+`/../content/webview/assets/app-test.png`)'
    assert_contains "$extracted/.vite/build/main-test.js" '(process.platform===`win32`||process.platform===`linux`)&&f===`local`'
    assert_contains "$extracted/.vite/build/main-test.js" 'setLinuxTrayContextMenu(){let e=n.Menu.buildFromTemplate(this.getNativeTrayMenuItems())'
    assert_contains "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&this.setLinuxTrayContextMenu(),this.tray.on(`click`'
    assert_contains "$extracted/.vite/build/main-test.js" 'process.platform===`linux`?this.openNativeTrayMenu():this.onTrayButtonClick()'
    assert_contains "$extracted/.vite/build/main-test.js" 'let e=process.platform===`linux`&&this.setLinuxTrayContextMenu?this.setLinuxTrayContextMenu():n.Menu.buildFromTemplate'
    assert_contains "$extracted/.vite/build/main-test.js" 'if(process.platform===`linux`)return;e.once(`menu-will-show`'
    assert_contains "$extracted/.vite/build/main-test.js" 'this.trayMenuThreads=e.trayMenuThreads,process.platform===`linux`&&this.setLinuxTrayContextMenu?.()'
    assert_contains "$extracted/.vite/build/main-test.js" '(E||process.platform===`linux`)&&oe();'
    assert_not_contains "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&this.tray.setContextMenu?.(e),this.tray.popUpContextMenu(e)'
    assert_not_contains "$output_log" 'WARN: Could not find tray'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'process.platform!==`linux`' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'nativeImage.createFromPath(process.resourcesPath' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'process.platform===`linux`)&&f===`local`' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'setLinuxTrayContextMenu(){' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&this.setLinuxTrayContextMenu(),this.tray.on(`click`' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'process.platform===`linux`?this.openNativeTrayMenu():this.onTrayButtonClick()' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'let e=process.platform===`linux`&&this.setLinuxTrayContextMenu?this.setLinuxTrayContextMenu():n.Menu.buildFromTemplate' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'if(process.platform===`linux`)return;e.once(`menu-will-show`' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&this.setLinuxTrayContextMenu?.()' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'process.platform===`linux`)&&oe' '1'
}

test_linux_single_instance_patch_smoke() {
    info "Checking Linux single-instance patch behavior"
    local workspace="$TMP_DIR/single-instance-patch"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"
    local bundle_body

    mkdir -p "$workspace"
    bundle_body="$(cat <<'JS'
let n={app:{whenReady(){},quit(){},requestSingleInstanceLock(){},on(){},off(){}}};
let t={Er(){return {info(){}}},jn:class{add(){}}};
async function uT(){let k=new t.jn;t.Er().info(`Launching app`,{safe:{agentRunId:process.env.CODEX_ELECTRON_AGENT_RUN_ID?.trim()||null}});let A=Date.now();await n.app.whenReady();let R={deepLinks:{queueProcessArgs(){return false}}},P={hotkeyWindowLifecycleManager:{hide(){}},getPrimaryWindow(){return null},createFreshLocalWindow(){return null}},g={reportNonFatal(){}},l=()=>{},re=e=>{e.isMinimized()&&e.restore(),e.show(),e.focus()},ie=async()=>{try{P.hotkeyWindowLifecycleManager.hide();let e=P.getPrimaryWindow(`local`)??await P.createFreshLocalWindow(`/`);if(e==null)return;re(e)}catch(e){g.reportNonFatal(e instanceof Error?e:`Failed to open window on second instance`,{kind:`second-instance-open-window-failed`})}};l(e=>{R.deepLinks.queueProcessArgs(e)||ie()});let ae=async()=>{}}
JS
)"
    make_fake_extracted_asar "$extracted" "$bundle_body"

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$extracted/.vite/build/main-test.js" 'process.platform===`linux`&&!n.app.requestSingleInstanceLock()'
    assert_contains "$extracted/.vite/build/main-test.js" 'codexLinuxSecondInstanceHandler'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_occurrence_count "$extracted/.vite/build/main-test.js" '!n.app.requestSingleInstanceLock()' '1'
    assert_occurrence_count "$extracted/.vite/build/main-test.js" 'codexLinuxSecondInstanceHandler' '3'
}

test_linux_file_manager_patch_fails_soft() {
    info "Checking Linux file manager patch fallback"
    local workspace="$TMP_DIR/file-manager-patch-fallback"
    local extracted="$workspace/extracted"
    local output_log="$workspace/output.log"

    mkdir -p "$workspace"
    make_fake_extracted_asar "$extracted" 'let D={removeMenu(){},setMenuBarVisibility(){},setIcon(){},once(){}};let t={join(){}};...process.platform===`win32`?{autoHideMenuBar:!0}:{},process.platform===`win32`&&D.removeMenu(),foo)}),D.once(`ready-to-show`,()=>{var brokenFileManager=Mi({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`});var Ua=Mi({id:`systemDefault`,label:`System Default App`,icon:`apps/file-explorer.png`,kind:`systemDefault`,hidden:!0,darwin:{icon:`apps/finder.png`,detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},win32:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)},linux:{detect:()=>`system-default`,iconPath:()=>null,args:e=>[e],open:async({path:e})=>Wa(e)}});async function Wa(e){return e}'

    node "$REPO_DIR/scripts/patch-linux-window-ui.js" "$extracted" >"$output_log" 2>&1
    assert_contains "$output_log" 'Failed to apply Linux File Manager Patch'
}

main() {
    test_common_helper_sourcing
    test_deb_builder_smoke
    test_rpm_builder_smoke
    test_missing_input_failure
    test_make_build_app_uses_installer_download_flow_by_default
    test_installer_detects_electron_version_from_plist
    test_installer_keeps_electron_fallback_for_bad_metadata
    test_launcher_template_sanity
    test_linux_file_manager_patch_smoke
    test_linux_translucent_sidebar_default_patch_smoke
    test_linux_tray_patch_smoke
    test_linux_single_instance_patch_smoke
    test_linux_file_manager_patch_fails_soft
    info "All script smoke tests passed"
}

main "$@"
