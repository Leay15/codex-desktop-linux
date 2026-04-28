#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const extractedDir = process.argv[2];

if (!extractedDir) {
  console.error("Usage: patch-linux-window-ui.js <extracted-app-asar-dir>");
  process.exit(1);
}

const assetsDir = path.join(extractedDir, "webview", "assets");
const iconAsset = fs
  .readdirSync(assetsDir)
  .find((name) => /^app-.*\.png$/.test(name));

if (!iconAsset) {
  console.warn(`WARN: Could not find app icon asset in ${assetsDir} — skipping all UI patches`);
  process.exit(0);
}

const buildDir = path.join(extractedDir, ".vite", "build");
const mainBundle = fs
  .readdirSync(buildDir)
  .find((name) => /^main(?:-[^.]+)?\.js$/.test(name));

if (!mainBundle) {
  console.warn(`WARN: Could not find main bundle in ${buildDir} — skipping all UI patches`);
  process.exit(0);
}

const target = path.join(buildDir, mainBundle);
let source = fs.readFileSync(target, "utf8");
const packageJsonPath = path.join(extractedDir, "package.json");
const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
const webviewAssetsDir = path.join(extractedDir, "webview", "assets");

function patchAssetFiles(filenamePattern, patchFn, missingWarnMessage) {
  if (!fs.existsSync(webviewAssetsDir)) {
    console.warn(`WARN: Could not find webview assets directory in ${webviewAssetsDir} — skipping asset patch`);
    return;
  }

  const candidates = fs
    .readdirSync(webviewAssetsDir)
    .filter((name) => filenamePattern.test(name))
    .sort();

  if (candidates.length === 0) {
    console.warn(missingWarnMessage);
    return;
  }

  for (const candidate of candidates) {
    const filePath = path.join(webviewAssetsDir, candidate);
    const currentSource = fs.readFileSync(filePath, "utf8");
    const patchedSource = patchFn(currentSource);
    if (patchedSource !== currentSource) {
      fs.writeFileSync(filePath, patchedSource, "utf8");
    }
  }
}

function applyLinuxOpaqueWindowsDefaultPatch(currentSource) {
  let patchedSource = currentSource;

  const mergeNeedle = "opaqueWindows:e?.opaqueWindows??n.opaqueWindows,semanticColors:";
  const mergePatch =
    "opaqueWindows:e?.opaqueWindows??(typeof navigator<`u`&&((navigator.userAgentData?.platform??navigator.platform??navigator.userAgent).toLowerCase().includes(`linux`))?!0:n.opaqueWindows),semanticColors:";

  if (patchedSource.includes("opaqueWindows:e?.opaqueWindows??(typeof navigator<`u`&&")) {
    // Already patched.
  } else if (patchedSource.includes(mergeNeedle)) {
    patchedSource = patchedSource.replace(mergeNeedle, mergePatch);
  } else if (patchedSource.includes("opaqueWindows") && patchedSource.includes("semanticColors")) {
    console.warn("WARN: Could not find Linux opaque window default insertion point — skipping settings default patch");
  }

  const settingsNeedle =
    "let d=ot(r,e),f=at(e),p={codeThemeId:tt(a,e).id,theme:d},";
  const settingsPatch =
    "let d=ot(r,e);navigator.userAgent.includes(`Linux`)&&r?.opaqueWindows==null&&(d={...d,opaqueWindows:!0});let f=at(e),p={codeThemeId:tt(a,e).id,theme:d},";
  if (patchedSource.includes("navigator.userAgent.includes(`Linux`)&&r?.opaqueWindows==null")) {
    // Already patched.
  } else if (patchedSource.includes(settingsNeedle)) {
    patchedSource = patchedSource.replace(settingsNeedle, settingsPatch);
  }

  const currentSettingsNeedle = "setThemePatch:b,theme:x}=ne(t),S=$t(i,t),";
  const currentSettingsPatch =
    "setThemePatch:b,theme:x}=ne(t);navigator.userAgent.includes(`Linux`)&&x?.opaqueWindows==null&&(x={...x,opaqueWindows:!0});let S=$t(i,t),";
  if (patchedSource.includes("navigator.userAgent.includes(`Linux`)&&x?.opaqueWindows==null")) {
    // Already patched.
  } else if (patchedSource.includes(currentSettingsNeedle)) {
    patchedSource = patchedSource.replace(currentSettingsNeedle, currentSettingsPatch);
  }

  const runtimeNeedle =
    "let T=o===`light`?C:w,E;if(T.opaqueWindows&&!XZ()){";
  const runtimePatch =
    "let T=o===`light`?C:w,E;document.documentElement.dataset.codexOs===`linux`&&((o===`light`?l:f)?.opaqueWindows==null&&(T={...T,opaqueWindows:!0}));if(T.opaqueWindows&&!XZ()){";
  if (patchedSource.includes("document.documentElement.dataset.codexOs===`linux`&&((o===`light`?l:f)?.opaqueWindows==null")) {
    // Already patched.
  } else if (patchedSource.includes(runtimeNeedle)) {
    patchedSource = patchedSource.replace(runtimeNeedle, runtimePatch);
  }

  const currentRuntimeNeedle = "let T=s===`light`?S:w,E;";
  const currentRuntimePatch =
    "let T=s===`light`?S:w,E;document.documentElement.dataset.codexOs===`linux`&&((s===`light`?u:p)?.opaqueWindows==null&&(T={...T,opaqueWindows:!0}));";
  if (patchedSource.includes("document.documentElement.dataset.codexOs===`linux`&&((s===`light`?u:p)?.opaqueWindows==null")) {
    // Already patched.
  } else if (patchedSource.includes(currentRuntimeNeedle)) {
    patchedSource = patchedSource.replace(currentRuntimeNeedle, currentRuntimePatch);
  }

  return patchedSource;
}

function applyLinuxFileManagerPatch(currentSource) {
  const fileManagerNeedle =
    "var sa=Mi({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>ai(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:ca,args:e=>ai(e),open:async({path:e})=>la(e)}});";
  const fileManagerLinuxPatch =
    "var sa=Mi({id:`fileManager`,label:`Finder`,icon:`apps/finder.png`,kind:`fileManager`,darwin:{detect:()=>`open`,args:e=>ai(e)},win32:{label:`File Explorer`,icon:`apps/file-explorer.png`,detect:ca,args:e=>ai(e),open:async({path:e})=>la(e)},linux:{label:`File Manager`,icon:`apps/file-explorer.png`,detect:()=>`linux-file-manager`,args:e=>[e],open:async({path:e})=>{let r=ua(e)??e,i=(0,a.existsSync)(r)&&(0,a.statSync)(r).isFile()?(0,t.dirname)(r):r,o=await n.shell.openPath(i);if(o)throw Error(o)}}});";
  const fileManagerId = "id:`fileManager`";
  const fileManagerBlockEnd = "function ca(){";
  const systemDefaultLinuxNeedle = "id:`systemDefault`";

  const fileManagerStart = currentSource.indexOf(fileManagerId);
  if (fileManagerStart === -1) {
    console.error("Failed to apply Linux File Manager Patch");
    return currentSource;
  }

  const fileManagerEnd = currentSource.indexOf(fileManagerBlockEnd, fileManagerStart);
  if (fileManagerEnd === -1) {
    console.error("Failed to apply Linux File Manager Patch");
    return currentSource;
  }

  const fileManagerBlock = currentSource.slice(fileManagerStart, fileManagerEnd);
  if (fileManagerBlock.includes("linux:{")) {
    return currentSource;
  }

  if (!currentSource.includes(fileManagerNeedle)) {
    console.error("Failed to apply Linux File Manager Patch");
    return currentSource;
  }

  const patchedSource = currentSource.replace(fileManagerNeedle, fileManagerLinuxPatch);
  const patchedFileManagerEnd = patchedSource.indexOf(fileManagerBlockEnd, fileManagerStart);
  if (patchedFileManagerEnd === -1) {
    console.error("Failed to apply Linux File Manager Patch");
    return currentSource;
  }

  const patchedFileManagerBlock = patchedSource.slice(fileManagerStart, patchedFileManagerEnd);
  const systemDefaultStart = patchedSource.indexOf(systemDefaultLinuxNeedle);
  const systemDefaultBlock = systemDefaultStart === -1
    ? ""
    : patchedSource.slice(
        systemDefaultStart,
        patchedSource.indexOf("async function Wa", systemDefaultStart),
      );

  if (
    !patchedFileManagerBlock.includes("linux:{label:`File Manager`") ||
    !patchedFileManagerBlock.includes("detect:()=>`linux-file-manager`") ||
    !patchedFileManagerBlock.includes("n.shell.openPath(i)") ||
    !systemDefaultBlock.includes("linux:{detect:()=>`system-default`")
  ) {
    console.error("Failed to apply Linux File Manager Patch");
    return currentSource;
  }

  return patchedSource;
}

function applyLinuxTrayPatch(currentSource, iconPathExpression) {
  let patchedSource = currentSource;

  const trayGuardNeedle =
    "process.platform!==`win32`&&process.platform!==`darwin`?null:";
  const trayGuardPatch =
    "process.platform!==`win32`&&process.platform!==`darwin`&&process.platform!==`linux`?null:";
  const trayGuardIndex = patchedSource.indexOf(trayGuardNeedle);
  if (patchedSource.includes(trayGuardPatch)) {
    // Already patched.
  } else if (
    trayGuardIndex !== -1 &&
    patchedSource.slice(trayGuardIndex, trayGuardIndex + 1200).includes("new n.Tray")
  ) {
    patchedSource = patchedSource.replace(trayGuardNeedle, trayGuardPatch);
  } else {
    console.warn("WARN: Could not find tray platform guard — skipping Linux tray guard patch");
  }

  const trayIconNeedle =
    "for(let e of o){let t=n.nativeImage.createFromPath(e);if(!t.isEmpty())return{defaultIcon:t,chronicleRunningIcon:null}}return{defaultIcon:await n.app.getFileIcon(process.execPath,{size:process.platform===`win32`?`small`:`normal`}),chronicleRunningIcon:null}}";
  const trayIconPatch =
    `for(let e of o){let t=n.nativeImage.createFromPath(e);if(!t.isEmpty())return{defaultIcon:t,chronicleRunningIcon:null}}if(process.platform===\`linux\`){let e=n.nativeImage.createFromPath(${iconPathExpression});if(!e.isEmpty())return{defaultIcon:e,chronicleRunningIcon:null}}return{defaultIcon:await n.app.getFileIcon(process.execPath,{size:process.platform===\`win32\`?\`small\`:\`normal\`}),chronicleRunningIcon:null}}`;
  if (patchedSource.includes(`nativeImage.createFromPath(${iconPathExpression})`)) {
    // Already patched.
  } else if (patchedSource.includes(trayIconNeedle)) {
    patchedSource = patchedSource.replace(trayIconNeedle, trayIconPatch);
  } else {
    console.warn("WARN: Could not find tray icon fallback — skipping Linux tray icon patch");
  }

  const closeToTrayNeedle =
    "if(process.platform===`win32`&&f===`local`&&!this.isAppQuitting&&this.options.canHideLastLocalWindowToTray?.()===!0&&!t){e.preventDefault(),k.hide();return}";
  const closeToTrayPatch =
    "if((process.platform===`win32`||process.platform===`linux`)&&f===`local`&&!this.isAppQuitting&&this.options.canHideLastLocalWindowToTray?.()===!0&&!t){e.preventDefault(),k.hide();return}";
  if (patchedSource.includes(closeToTrayPatch)) {
    // Already patched.
  } else if (patchedSource.includes(closeToTrayNeedle)) {
    patchedSource = patchedSource.replace(closeToTrayNeedle, closeToTrayPatch);
  } else {
    console.warn("WARN: Could not find close-to-tray condition — skipping Linux close-to-tray patch");
  }

  const trayContextMethodNeedle =
    "trayMenuThreads={runningThreads:[],unreadThreads:[],pinnedThreads:[],recentThreads:[],usageLimits:[]};constructor(";
  const trayContextMethodPatch =
    "trayMenuThreads={runningThreads:[],unreadThreads:[],pinnedThreads:[],recentThreads:[],usageLimits:[]};setLinuxTrayContextMenu(){let e=n.Menu.buildFromTemplate(this.getNativeTrayMenuItems());this.tray.setContextMenu?.(e);return e}constructor(";
  if (patchedSource.includes("setLinuxTrayContextMenu(){")) {
    // Already patched.
  } else if (patchedSource.includes(trayContextMethodNeedle)) {
    patchedSource = patchedSource.replace(trayContextMethodNeedle, trayContextMethodPatch);
  } else {
    console.warn("WARN: Could not find tray controller fields — skipping Linux tray context menu method patch");
  }

  const trayClickNeedle =
    "this.tray.on(`click`,()=>{this.onTrayButtonClick()}),this.tray.on(`right-click`,()=>{this.openNativeTrayMenu()})}";
  const trayClickPatchWithoutContextSetup =
    "this.tray.on(`click`,()=>{process.platform===`linux`?this.openNativeTrayMenu():this.onTrayButtonClick()}),this.tray.on(`right-click`,()=>{this.openNativeTrayMenu()})}";
  const trayClickPatch =
    "process.platform===`linux`&&this.setLinuxTrayContextMenu(),this.tray.on(`click`,()=>{process.platform===`linux`?this.openNativeTrayMenu():this.onTrayButtonClick()}),this.tray.on(`right-click`,()=>{this.openNativeTrayMenu()})}";
  const canSetLinuxTrayContextMenu = patchedSource.includes("setLinuxTrayContextMenu(){");
  if (patchedSource.includes("process.platform===`linux`&&this.setLinuxTrayContextMenu(),this.tray.on(`click`")) {
    // Already patched.
  } else if (patchedSource.includes(trayClickNeedle)) {
    patchedSource = patchedSource.replace(
      trayClickNeedle,
      canSetLinuxTrayContextMenu ? trayClickPatch : trayClickPatchWithoutContextSetup,
    );
  } else if (canSetLinuxTrayContextMenu && patchedSource.includes(trayClickPatchWithoutContextSetup)) {
    patchedSource = patchedSource.replace(trayClickPatchWithoutContextSetup, trayClickPatch);
  } else {
    console.warn("WARN: Could not find tray click handler — skipping Linux tray menu click patch");
  }

  const trayMenuBuildNeedle =
    "openNativeTrayMenu(){this.updateChronicleTrayIcon();let e=n.Menu.buildFromTemplate(this.getNativeTrayMenuItems());";
  const trayMenuBuildPatch =
    "openNativeTrayMenu(){this.updateChronicleTrayIcon();let e=process.platform===`linux`&&this.setLinuxTrayContextMenu?this.setLinuxTrayContextMenu():n.Menu.buildFromTemplate(this.getNativeTrayMenuItems());";
  if (patchedSource.includes("let e=process.platform===`linux`&&this.setLinuxTrayContextMenu?")) {
    // Already patched.
  } else if (patchedSource.includes(trayMenuBuildNeedle)) {
    patchedSource = patchedSource.replace(trayMenuBuildNeedle, trayMenuBuildPatch);
  } else {
    console.warn("WARN: Could not find tray native menu builder — skipping Linux tray context menu builder patch");
  }

  const trayContextMenuNeedle =
    "e.once(`menu-will-show`,()=>{this.isNativeTrayMenuOpen=!0}),e.once(`menu-will-close`,()=>{this.isNativeTrayMenuOpen=!1,this.handleNativeTrayMenuClosed()}),this.tray.popUpContextMenu(e)}";
  const trayContextMenuPatch =
    "if(process.platform===`linux`)return;e.once(`menu-will-show`,()=>{this.isNativeTrayMenuOpen=!0}),e.once(`menu-will-close`,()=>{this.isNativeTrayMenuOpen=!1,this.handleNativeTrayMenuClosed()}),this.tray.popUpContextMenu(e)}";
  const oldLinuxPopupPatch =
    "e.once(`menu-will-show`,()=>{this.isNativeTrayMenuOpen=!0}),e.once(`menu-will-close`,()=>{this.isNativeTrayMenuOpen=!1,this.handleNativeTrayMenuClosed()}),process.platform===`linux`&&this.tray.setContextMenu?.(e),this.tray.popUpContextMenu(e)}";
  const badLinuxPopupPatch =
    "e.once(`menu-will-show`,()=>{this.isNativeTrayMenuOpen=!0}),if(process.platform===`linux`)return;e.once(`menu-will-close`,()=>{this.isNativeTrayMenuOpen=!1,this.handleNativeTrayMenuClosed()}),this.tray.popUpContextMenu(e)}";
  if (patchedSource.includes("if(process.platform===`linux`)return;e.once(`menu-will-show`")) {
    // Already patched.
  } else if (patchedSource.includes(badLinuxPopupPatch)) {
    patchedSource = patchedSource.replace(badLinuxPopupPatch, trayContextMenuPatch);
  } else if (patchedSource.includes(oldLinuxPopupPatch)) {
    patchedSource = patchedSource.replace(oldLinuxPopupPatch, trayContextMenuPatch);
  } else if (patchedSource.includes(trayContextMenuNeedle)) {
    patchedSource = patchedSource.replace(trayContextMenuNeedle, trayContextMenuPatch);
  } else {
    console.warn("WARN: Could not find tray native menu popup — skipping Linux tray popup guard patch");
  }

  const trayMenuThreadsNeedle =
    "case`tray-menu-threads-changed`:this.trayMenuThreads=e.trayMenuThreads;return";
  const trayMenuThreadsPatch =
    "case`tray-menu-threads-changed`:this.trayMenuThreads=e.trayMenuThreads,process.platform===`linux`&&this.setLinuxTrayContextMenu?.();return";
  if (patchedSource.includes("this.trayMenuThreads=e.trayMenuThreads,process.platform===`linux`&&this.setLinuxTrayContextMenu?.()")) {
    // Already patched.
  } else if (patchedSource.includes(trayMenuThreadsNeedle)) {
    patchedSource = patchedSource.replace(trayMenuThreadsNeedle, trayMenuThreadsPatch);
  } else {
    console.warn("WARN: Could not find tray menu thread update handler — skipping Linux tray context refresh patch");
  }

  const trayStartupNeedle = "E&&oe();";
  const trayStartupPatch = "(E||process.platform===`linux`)&&oe();";
  if (patchedSource.includes(trayStartupPatch)) {
    // Already patched.
  } else if (patchedSource.includes(trayStartupNeedle)) {
    patchedSource = patchedSource.replace(trayStartupNeedle, trayStartupPatch);
  } else {
    console.warn("WARN: Could not find tray startup call — skipping Linux tray startup patch");
  }

  return patchedSource;
}

function applyLinuxSingleInstancePatch(currentSource) {
  let patchedSource = currentSource;

  const singleInstanceLockNeedle =
    "agentRunId:process.env.CODEX_ELECTRON_AGENT_RUN_ID?.trim()||null}});let A=Date.now();await n.app.whenReady()";
  const singleInstanceLockPatch =
    "agentRunId:process.env.CODEX_ELECTRON_AGENT_RUN_ID?.trim()||null}});if(process.platform===`linux`&&!n.app.requestSingleInstanceLock()){n.app.quit();return}let A=Date.now();await n.app.whenReady()";
  if (patchedSource.includes("process.platform===`linux`&&!n.app.requestSingleInstanceLock()")) {
    // Already patched.
  } else if (patchedSource.includes(singleInstanceLockNeedle)) {
    patchedSource = patchedSource.replace(singleInstanceLockNeedle, singleInstanceLockPatch);
  } else {
    console.warn("WARN: Could not find startup handoff point — skipping Linux single-instance lock patch");
  }

  const secondInstanceHandlerNeedle =
    "l(e=>{R.deepLinks.queueProcessArgs(e)||ie()});let ae=";
  const secondInstanceHandlerPatch =
    "let codexLinuxSecondInstanceHandler=(e,t)=>{R.deepLinks.queueProcessArgs(t)||ie()};process.platform===`linux`&&(n.app.on(`second-instance`,codexLinuxSecondInstanceHandler),k.add(()=>{n.app.off(`second-instance`,codexLinuxSecondInstanceHandler)})),l(e=>{R.deepLinks.queueProcessArgs(e)||ie()});let ae=";
  if (patchedSource.includes("codexLinuxSecondInstanceHandler")) {
    // Already patched.
  } else if (patchedSource.includes(secondInstanceHandlerNeedle)) {
    patchedSource = patchedSource.replace(secondInstanceHandlerNeedle, secondInstanceHandlerPatch);
  } else {
    console.warn("WARN: Could not find second-instance handler — skipping Linux second-instance focus patch");
  }

  return patchedSource;
}


const windowOptionsNeedle =
  "...process.platform===`win32`?{autoHideMenuBar:!0}:{},";
const iconPathExpression =
  `process.resourcesPath+\`/../content/webview/assets/${iconAsset}\``;
const iconPathNeedle =
  `icon:${iconPathExpression}`;
const windowOptionsReplacement =
  `...process.platform===\`win32\`||process.platform===\`linux\`?{autoHideMenuBar:!0,...process.platform===\`linux\`?{${iconPathNeedle}}:{}}:{},`;

if (source.includes(windowOptionsNeedle)) {
  source = source.replace(windowOptionsNeedle, windowOptionsReplacement);
} else if (!source.includes(iconPathNeedle)) {
  console.warn("WARN: Could not find BrowserWindow autoHideMenuBar snippet — skipping window options patch");
}

const menuNeedle = "process.platform===`win32`&&D.removeMenu(),";
const menuPatch = "process.platform===`linux`&&D.setMenuBarVisibility(!1),";
const menuReplacement = `${menuPatch}${menuNeedle}`;

if (source.includes(menuNeedle) && !source.includes(menuPatch)) {
  source = source.replace(menuNeedle, menuReplacement);
} else if (!source.includes(menuPatch)) {
  console.warn("WARN: Could not find window menu visibility snippet — skipping menu patch");
}

const setIconNeedle =
  ")}),D.once(`ready-to-show`,()=>{";
const setIconPatch =
  `)}),process.platform===\`linux\`&&D.setIcon(${iconPathExpression}),D.once(\`ready-to-show\`,()=>{`;

if (source.includes(setIconNeedle) && !source.includes("&&D.setIcon(")) {
  source = source.replace(setIconNeedle, setIconPatch);
} else if (!source.includes("&&D.setIcon(")) {
  console.warn("WARN: Could not find window setIcon insertion point — skipping setIcon patch");
}

// Patch 4: Replace transparent BrowserWindow background with opaque colors on Linux.
// On macOS vibrancy handles transparency; on Linux there is no compositor equivalent,
// so the transparent background causes flickering when the window moves or on hover.
const colorConstRegex = /([A-Za-z_$][\w$]*)=`#00000000`,([A-Za-z_$][\w$]*)=`#000000`,([A-Za-z_$][\w$]*)=`#f9f9f9`/;
const colorMatch = source.match(colorConstRegex);

if (colorMatch) {
  const [, transparentVar, darkVar, lightVar] = colorMatch;

  // Capture the prefersDarkColors parameter name from the background function signature.
  const funcParamRegex = /prefersDarkColors:([A-Za-z_$][\w$]*)\}\)\{return\s*([A-Za-z_$][\w$]*)===`win32`/;
  const funcMatch = source.match(funcParamRegex);

  if (funcMatch) {
    const darkColorsParam = funcMatch[1];

    const bgNeedle =
      `backgroundMaterial:\`mica\`}:{backgroundColor:${transparentVar},backgroundMaterial:null}}`;
    const bgReplacement =
      `backgroundMaterial:\`mica\`}:process.platform===\`linux\`?{backgroundColor:${darkColorsParam}?${darkVar}:${lightVar},backgroundMaterial:null}:{backgroundColor:${transparentVar},backgroundMaterial:null}}`;

    if (source.includes(bgNeedle)) {
      source = source.replace(bgNeedle, bgReplacement);
    } else {
      console.warn("WARN: Could not find BrowserWindow background color needle — skipping background patch");
    }
  } else {
    console.warn("WARN: Could not find prefersDarkColors parameter — skipping background patch");
  }
} else {
  console.warn("WARN: Could not find color constants (#00000000, #000000, #f9f9f9) — skipping background patch");
}

source = applyLinuxFileManagerPatch(source);
source = applyLinuxTrayPatch(source, iconPathExpression);
source = applyLinuxSingleInstancePatch(source);

fs.writeFileSync(target, source, "utf8");

patchAssetFiles(
  /^code-theme-.*\.js$/,
  applyLinuxOpaqueWindowsDefaultPatch,
  `WARN: Could not find code theme bundle in ${webviewAssetsDir} — skipping translucent sidebar default patch`,
);
patchAssetFiles(
  /^general-settings-.*\.js$/,
  applyLinuxOpaqueWindowsDefaultPatch,
  `WARN: Could not find general settings bundle in ${webviewAssetsDir} — skipping translucent sidebar default patch`,
);
patchAssetFiles(
  /^index-.*\.js$/,
  applyLinuxOpaqueWindowsDefaultPatch,
  `WARN: Could not find webview index bundle in ${webviewAssetsDir} — skipping translucent sidebar default patch`,
);
patchAssetFiles(
  /^use-resolved-theme-variant-.*\.js$/,
  applyLinuxOpaqueWindowsDefaultPatch,
  `WARN: Could not find resolved theme bundle in ${webviewAssetsDir} — skipping translucent sidebar default patch`,
);

if (packageJson.desktopName !== "codex-desktop.desktop") {
  packageJson.desktopName = "codex-desktop.desktop";
  fs.writeFileSync(packageJsonPath, `${JSON.stringify(packageJson, null, 2)}\n`, "utf8");
}

console.log("Patched Linux window, shell, tray, and appearance behavior:", {
  target,
  mainBundle,
  iconAsset,
  desktopName: packageJson.desktopName,
});
