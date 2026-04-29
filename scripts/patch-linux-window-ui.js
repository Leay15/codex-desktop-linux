#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

function readDirectoryNames(dir) {
  if (!fs.existsSync(dir)) {
    return [];
  }
  return fs.readdirSync(dir);
}

function findMainBundle(extractedDir) {
  const buildDir = path.join(extractedDir, ".vite", "build");
  const mainBundle = readDirectoryNames(buildDir).find((name) =>
    /^main(?:-[^.]+)?\.js$/.test(name),
  );

  return mainBundle == null ? null : { buildDir, mainBundle };
}

function findIconAsset(extractedDir) {
  const assetsDir = path.join(extractedDir, "webview", "assets");
  return readDirectoryNames(assetsDir).find((name) => /^app-.*\.png$/.test(name)) ?? null;
}

const keybindsSettingsAsset = "keybinds-settings-linux.js";
const linuxKeybindOverridesKey = "codex-linux-keybind-overrides";

const linuxSettingsKeys = {
  promptWindow: "codex-linux-prompt-window-enabled",
  systemTray: "codex-linux-system-tray-enabled",
  warmStart: "codex-linux-warm-start-enabled",
};

function patchAssetFiles(extractedDir, filenamePattern, patchFn, missingWarnMessage) {
  const webviewAssetsDir = path.join(extractedDir, "webview", "assets");
  if (!fs.existsSync(webviewAssetsDir)) {
    console.warn(
      `WARN: Could not find webview assets directory in ${webviewAssetsDir} — skipping asset patch`,
    );
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

function readWebviewAsset(webviewAssetsDir, assetName) {
  return fs.readFileSync(path.join(webviewAssetsDir, assetName), "utf8");
}

function findRequiredWebviewAsset(webviewAssetsDir, filenamePattern, marker, description) {
  if (!fs.existsSync(webviewAssetsDir)) {
    throw new Error(`Required Keybinds settings patch failed: missing webview assets directory ${webviewAssetsDir}`);
  }

  const candidates = fs
    .readdirSync(webviewAssetsDir)
    .filter((name) => filenamePattern.test(name))
    .sort();
  const matches = marker == null
    ? candidates
    : candidates.filter((name) => readWebviewAsset(webviewAssetsDir, name).includes(marker));

  if (matches.length === 0) {
    throw new Error(`Required Keybinds settings patch failed: could not find ${description}`);
  }

  return matches[0];
}

function findImportedAsset(webviewAssetsDir, importerAsset, description) {
  const importedAsset = readWebviewAsset(webviewAssetsDir, importerAsset).match(/from"\.\/([^"]+)"/)?.[1];
  if (!importedAsset || !fs.existsSync(path.join(webviewAssetsDir, importedAsset))) {
    throw new Error(`Required Keybinds settings patch failed: could not find ${description}`);
  }
  return importedAsset;
}

function buildKeybindsSettingsSource({
  chunkAsset,
  reactAsset,
  jsxRuntimeAsset,
  vscodeApiAsset,
  hotkeySettingsAsset,
  toggleAsset,
  settingsRowAsset,
  settingsLayoutAsset,
}) {
  const keybindGroups = [
    {
      title: "Core",
      actions: [
        { id: "newThread", label: "New chat", description: "Start a new chat." },
        { id: "quickChat", label: "Quick chat", description: "Open a quick chat window." },
        { id: "newThreadAlt", label: "New chat alternate", description: "Alternate shortcut for a new chat." },
        { id: "openFolder", label: "Open folder", description: "Open a workspace folder." },
        { id: "settings", label: "Settings", description: "Open settings." },
        { id: "openCommandMenu", label: "Command menu", description: "Open the command menu." },
        { id: "openCommandMenuAlt", label: "Command menu alternate", description: "Alternate shortcut for the command menu." },
        { id: "searchChats", label: "Search chats", description: "Search existing chats." },
        { id: "searchFiles", label: "Search files", description: "Search files in the current workspace." },
        { id: "newWindow", label: "New window", description: "Open a new app window." },
      ],
    },
    {
      title: "Thread",
      actions: [
        { id: "findInThread", label: "Find in thread", description: "Search inside the current thread." },
        { id: "copyConversationPath", label: "Copy conversation path", description: "Copy the current conversation path." },
        { id: "toggleThreadPin", label: "Toggle thread pin", description: "Pin or unpin the current thread." },
        { id: "renameThread", label: "Rename thread", description: "Rename the current thread." },
        { id: "archiveThread", label: "Archive thread", description: "Archive the current thread." },
        { id: "copyWorkingDirectory", label: "Copy working directory", description: "Copy the current working directory." },
        { id: "copySessionId", label: "Copy session ID", description: "Copy the current session ID." },
        { id: "copyDeeplink", label: "Copy deeplink", description: "Copy a deeplink for the current thread." },
        { id: "previousThread", label: "Previous thread", description: "Move to the previous thread." },
        { id: "nextThread", label: "Next thread", description: "Move to the next thread." },
        { id: "thread1", label: "Thread 1", description: "Jump to thread slot 1." },
        { id: "thread2", label: "Thread 2", description: "Jump to thread slot 2." },
        { id: "thread3", label: "Thread 3", description: "Jump to thread slot 3." },
        { id: "thread4", label: "Thread 4", description: "Jump to thread slot 4." },
        { id: "thread5", label: "Thread 5", description: "Jump to thread slot 5." },
        { id: "thread6", label: "Thread 6", description: "Jump to thread slot 6." },
        { id: "thread7", label: "Thread 7", description: "Jump to thread slot 7." },
        { id: "thread8", label: "Thread 8", description: "Jump to thread slot 8." },
        { id: "thread9", label: "Thread 9", description: "Jump to thread slot 9." },
      ],
    },
    {
      title: "Panels",
      actions: [
        { id: "toggleSidebar", label: "Toggle sidebar", description: "Show or hide the sidebar." },
        { id: "toggleTerminal", label: "Toggle terminal", description: "Show or hide the terminal." },
        { id: "toggleFileTreePanel", label: "Toggle file tree", description: "Show or hide the file tree." },
        { id: "openBrowserTab", label: "Open browser tab", description: "Open a browser tab." },
        { id: "reloadBrowserPage", label: "Reload browser page", description: "Reload the active browser page." },
        { id: "hardReloadBrowserPage", label: "Hard reload browser page", description: "Hard reload the active browser page." },
        { id: "toggleBrowserPanel", label: "Toggle browser panel", description: "Show or hide the browser panel." },
        { id: "toggleDiffPanel", label: "Toggle review panel", description: "Show or hide the review panel." },
        { id: "openThreadOverlay", label: "Open thread switcher", description: "Open the thread switcher." },
        { id: "openAvatarOverlay", label: "Open account menu", description: "Open the account menu." },
      ],
    },
    {
      title: "System",
      actions: [
        { id: "toggleTraceRecording", label: "Toggle trace recording", description: "Start or stop trace recording." },
        { id: "dictation", label: "Dictation", description: "Start dictation." },
      ],
    },
  ];

  return `import{s as __toESM}from"./${chunkAsset}";import{t as __reactFactory}from"./${reactAsset}";import{t as __jsxFactory}from"./${jsxRuntimeAsset}";import{n as __post,rn as DEFAULT_SHORTCUTS}from"./${vscodeApiAsset}";import{i as HotkeyWindowHotkeyRow}from"./${hotkeySettingsAsset}";import{t as Toggle}from"./${toggleAsset}";import{n as SettingsRow}from"./${settingsRowAsset}";import{r as SettingsSection,n as SettingsGroup,t as SettingsPage}from"./${settingsLayoutAsset}";var React=__toESM(__reactFactory(),1),$=__jsxFactory(),KEYS={promptWindow:${JSON.stringify(linuxSettingsKeys.promptWindow)},systemTray:${JSON.stringify(linuxSettingsKeys.systemTray)},warmStart:${JSON.stringify(linuxSettingsKeys.warmStart)}},KEYBIND_OVERRIDES_KEY=${JSON.stringify(linuxKeybindOverridesKey)},KEYBIND_GROUPS=${JSON.stringify(keybindGroups)};function normalizeOverrides(value){if(!value||typeof value!="object"||Array.isArray(value))return{};return Object.fromEntries(Object.entries(value).filter(([key,accelerator])=>typeof key=="string"&&typeof accelerator=="string"&&accelerator.trim().length>0).map(([key,accelerator])=>[key,accelerator.trim()]))}function readLocalOverrides(){try{return normalizeOverrides(JSON.parse(localStorage.getItem(KEYBIND_OVERRIDES_KEY)||"{}"))}catch{return{}}}function writeLocalOverrides(next){try{localStorage.setItem(KEYBIND_OVERRIDES_KEY,JSON.stringify(next)),window.dispatchEvent(new CustomEvent("codex-linux-keybind-overrides-changed",{detail:next}))}catch{}}function useKeybindOverrides(){let[overrides,setOverrides]=React.useState(()=>readLocalOverrides()),[error,setError]=React.useState(null);React.useEffect(()=>{let alive=!0;__post("get-global-state",{params:{key:KEYBIND_OVERRIDES_KEY}}).then(result=>{if(!alive)return;let next=normalizeOverrides(result?.value);Object.keys(next).length>0?(setOverrides(next),writeLocalOverrides(next)):setOverrides(readLocalOverrides());setError(null)}).catch(err=>{alive&&setError(err instanceof Error?err.message:String(err))});return()=>{alive=!1}},[]);let update=React.useCallback((actionId,accelerator)=>{setOverrides(previous=>{let next={...previous},defaultValue=typeof DEFAULT_SHORTCUTS[actionId]=="string"?DEFAULT_SHORTCUTS[actionId]:"",trimmed=String(accelerator??"").trim();trimmed.length===0||trimmed===defaultValue?delete next[actionId]:next[actionId]=trimmed;writeLocalOverrides(next);__post("set-global-state",{params:{key:KEYBIND_OVERRIDES_KEY,value:next}}).then(()=>setError(null)).catch(err=>setError(err instanceof Error?err.message:String(err)));return next})},[]);return{overrides,error,update}}function useLinuxSetting(key,defaultValue){let[value,setValue]=React.useState(defaultValue),[isLoading,setIsLoading]=React.useState(!0),[error,setError]=React.useState(null);React.useEffect(()=>{let alive=!0;setIsLoading(!0);__post("get-global-state",{params:{key}}).then(result=>{alive&&(setValue(result?.value??defaultValue),setError(null))}).catch(err=>{alive&&setError(err instanceof Error?err.message:String(err))}).finally(()=>{alive&&setIsLoading(!1)});return()=>{alive=!1}},[key,defaultValue]);let update=React.useCallback(next=>{let previous=value;setValue(next);setError(null);__post("set-global-state",{params:{key,value:next}}).catch(err=>{setValue(previous);setError(err instanceof Error?err.message:String(err))})},[key,value]);return{value,isLoading,error,update}}function LinuxToggle({settingKey,label,description,defaultValue=!0}){let{value,isLoading,error,update}=useLinuxSetting(settingKey,defaultValue),details=error?$.jsxs("div",{className:"flex flex-col gap-1",children:[$.jsx("span",{children:description}),$.jsx("span",{className:"text-token-error-foreground",children:error})]}):description;return $.jsx(SettingsRow,{label,description:details,control:$.jsx(Toggle,{checked:value,disabled:isLoading,onChange:update,ariaLabel:label})})}function normalizeCapturedKey(key){let map={" ":"Space",ArrowUp:"Up",ArrowDown:"Down",ArrowLeft:"Left",ArrowRight:"Right",Escape:"Esc",",":",",".":".","/":"/","\\\\":"\\\\","[":"[","]":"]",";":";","'":"'","-":"-","=":"=","+":"Plus"};if(map[key])return map[key];if(/^.$/.test(key))return key.toUpperCase();return key}function formatAcceleratorForInput(event){if(!(event.ctrlKey||event.altKey||event.metaKey))return null;if(["Control","Shift","Alt","Meta"].includes(event.key))return null;let parts=[];event.ctrlKey&&parts.push("Ctrl");event.altKey&&parts.push("Alt");event.shiftKey&&parts.push("Shift");event.metaKey&&parts.push("Command");let key=normalizeCapturedKey(event.key);return key?[...parts,key].join("+"):null}function ShortcutInput({value,defaultValue,changed,onChange}){let[draft,setDraft]=React.useState(value);React.useEffect(()=>setDraft(value),[value]);let commit=next=>onChange(String(next??"").trim());return $.jsxs("div",{className:"flex min-w-[260px] items-center justify-end gap-2",children:[$.jsx("input",{className:"h-8 w-[190px] rounded-md border border-token-border-default bg-token-bg-primary px-2 text-sm text-token-text-primary outline-none focus:border-token-border-strong","data-codex-keybind-input":!0,value:draft,placeholder:defaultValue,onChange:event=>{setDraft(event.target.value),onChange(event.target.value)},onBlur:()=>commit(draft),onKeyDown:event=>{if(event.key==="Escape"){setDraft(value);return}if(event.key==="Enter"){event.preventDefault(),commit(draft);return}let captured=formatAcceleratorForInput(event);captured&&(event.preventDefault(),setDraft(captured),onChange(captured))}}),$.jsx("button",{type:"button",className:"h-8 rounded-md border border-token-border-default px-2 text-xs text-token-text-secondary disabled:opacity-40",disabled:!changed,onClick:()=>onChange(""),children:"Reset"})]})}function KeybindRow({action,overrides,update}){let defaultValue=typeof DEFAULT_SHORTCUTS[action.id]=="string"?DEFAULT_SHORTCUTS[action.id]:action.defaultAccelerator??"",hasOverride=Object.prototype.hasOwnProperty.call(overrides,action.id),value=hasOverride?overrides[action.id]:defaultValue,changed=hasOverride&&value!==defaultValue,description=$.jsxs("div",{className:"flex flex-col gap-1",children:[$.jsx("span",{children:action.description}),$.jsxs("span",{className:"text-token-text-tertiary",children:["Default: ",defaultValue||"Unassigned"]})]});return $.jsx(SettingsRow,{label:action.label,description,control:$.jsx(ShortcutInput,{value,defaultValue,changed,onChange:next=>update(action.id,next)})})}function KeybindGroup({group,overrides,update}){return $.jsxs(SettingsSection,{className:"gap-2",children:[$.jsx(SettingsSection.Header,{title:group.title}),$.jsx(SettingsSection.Content,{children:$.jsx(SettingsGroup,{children:group.actions.map(action=>$.jsx(KeybindRow,{action,overrides,update},action.id))})})]},group.title)}function KeybindsSettings(){let{overrides,error,update}=useKeybindOverrides();return $.jsx(SettingsPage,{title:"Keybinds",subtitle:"App shortcuts and Linux desktop behavior.",children:$.jsxs("div",{className:"flex flex-col gap-6",children:[$.jsxs(SettingsSection,{className:"gap-2",children:[$.jsx(SettingsSection.Header,{title:"App shortcuts"}),error?$.jsx("div",{className:"px-1 text-sm text-token-error-foreground",children:error}):null]}),...KEYBIND_GROUPS.map(group=>$.jsx(KeybindGroup,{group,overrides,update},group.title)),$.jsxs(SettingsSection,{className:"gap-2",children:[$.jsx(SettingsSection.Header,{title:"Global shortcuts"}),$.jsx(SettingsSection.Content,{children:$.jsxs(SettingsGroup,{children:[$.jsx(HotkeyWindowHotkeyRow,{}),$.jsx(LinuxToggle,{settingKey:KEYS.promptWindow,label:"Compact prompt window",description:"Allow --prompt-chat and --hotkey-window to open the compact prompt window and keep it prewarmed."})]})})]}),$.jsxs(SettingsSection,{className:"gap-2",children:[$.jsx(SettingsSection.Header,{title:"Linux desktop"}),$.jsx(SettingsSection.Content,{children:$.jsxs(SettingsGroup,{children:[$.jsx(LinuxToggle,{settingKey:KEYS.systemTray,label:"System tray",description:"Show the Codex system tray icon and keep the app available from the tray."}),$.jsx(LinuxToggle,{settingKey:KEYS.warmStart,label:"Warm start",description:"Use the running app for launch actions instead of starting a fresh Electron instance."})]})})]})]})})}export{KeybindsSettings,KeybindsSettings as default};\n//# sourceMappingURL=${keybindsSettingsAsset}.map\n`;
}

function resolveKeybindsSettingsAsset(extractedDir) {
  const webviewAssetsDir = path.join(extractedDir, "webview", "assets");
  if (!fs.existsSync(webviewAssetsDir)) {
    throw new Error(`Required Keybinds settings patch failed: missing webview assets directory ${webviewAssetsDir}`);
  }

  const reactAsset = findRequiredWebviewAsset(webviewAssetsDir, /^react-.*\.js$/, "react.transitional.element", "React asset");
  const chunkAsset = findImportedAsset(webviewAssetsDir, reactAsset, "React shared chunk asset");
  const jsxRuntimeAsset = findRequiredWebviewAsset(webviewAssetsDir, /^jsx-runtime-.*\.js$/, "react.transitional.element", "JSX runtime asset");
  const vscodeApiAsset = findRequiredWebviewAsset(webviewAssetsDir, /^vscode-api-.*\.js$/, "vscode://codex", "VS Code API asset");
  const hotkeySettingsAsset = findRequiredWebviewAsset(
    webviewAssetsDir,
    /^general-settings-.*\.js$/,
    "hotkey-window-hotkey-state",
    "hotkey settings asset",
  );
  const toggleAsset = findRequiredWebviewAsset(webviewAssetsDir, /^toggle-.*\.js$/, null, "toggle asset");
  const settingsRowAsset = findRequiredWebviewAsset(webviewAssetsDir, /^settings-row-.*\.js$/, null, "settings row asset");
  const settingsLayoutAsset = findRequiredWebviewAsset(
    webviewAssetsDir,
    /^settings-content-layout-.*\.js$/,
    null,
    "settings content layout asset",
  );
  const filePath = path.join(webviewAssetsDir, keybindsSettingsAsset);

  return {
    filePath,
    source: buildKeybindsSettingsSource({
      chunkAsset,
      reactAsset,
      jsxRuntimeAsset,
      vscodeApiAsset,
      hotkeySettingsAsset,
      toggleAsset,
      settingsRowAsset,
      settingsLayoutAsset,
    }),
  };
}

function collectRequiredAssetPatches(extractedDir, filenamePattern, patchFn, description) {
  const webviewAssetsDir = path.join(extractedDir, "webview", "assets");
  if (!fs.existsSync(webviewAssetsDir)) {
    throw new Error(`Required Keybinds settings patch failed: missing webview assets directory ${webviewAssetsDir}`);
  }

  const candidates = fs
    .readdirSync(webviewAssetsDir)
    .filter((name) => filenamePattern.test(name))
    .sort();
  if (candidates.length === 0) {
    throw new Error(`Required Keybinds settings patch failed: could not find ${description}`);
  }

  return candidates.map((candidate) => {
    const filePath = path.join(webviewAssetsDir, candidate);
    const currentSource = fs.readFileSync(filePath, "utf8");
    return {
      filePath,
      currentSource,
      patchedSource: patchFn(currentSource),
    };
  });
}

function patchKeybindsSettingsAssets(extractedDir) {
  try {
    const keybindsAsset = resolveKeybindsSettingsAsset(extractedDir);
    const patches = [
      ...collectRequiredAssetPatches(
        extractedDir,
        /^settings-sections-.*\.js$/,
        applyKeybindsSettingsSectionsPatch,
        "settings sections bundle",
      ),
      ...collectRequiredAssetPatches(
        extractedDir,
        /^settings-shared-.*\.js$/,
        applyKeybindsSettingsSharedPatch,
        "settings shared bundle",
      ),
      ...collectRequiredAssetPatches(
        extractedDir,
        /^index-.*\.js$/,
        applyKeybindsSettingsIndexPatch,
        "webview index bundle",
      ),
    ];

    fs.writeFileSync(keybindsAsset.filePath, keybindsAsset.source, "utf8");
    for (const patch of patches) {
      if (patch.patchedSource !== patch.currentSource) {
        fs.writeFileSync(patch.filePath, patch.patchedSource, "utf8");
      }
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.warn(`WARN: Keybinds settings patch skipped: ${message}`);
  }
}

function applyKeybindsSettingsSectionsPatch(currentSource) {
  let patchedSource = currentSource;

  if (patchedSource.includes("slug:`keybinds`")) {
    return patchedSource;
  }

  const sectionsNeedle = "var e=`general-settings`,t=`mcp-settings`,n=[{slug:e},";
  const sectionsPatch = "var e=`general-settings`,t=`mcp-settings`,n=[{slug:e},{slug:`keybinds`},";
  if (patchedSource.includes(sectionsNeedle)) {
    return patchedSource.replace(sectionsNeedle, sectionsPatch);
  }

  const currentNeedle = "n=[{slug:e},{slug:`appearance`}";
  if (patchedSource.includes(currentNeedle)) {
    return patchedSource.replace(currentNeedle, "n=[{slug:e},{slug:`keybinds`},{slug:`appearance`}");
  }

  const literalNeedle = "n=[{slug:`general-settings`},{slug:`appearance`}";
  if (patchedSource.includes(literalNeedle)) {
    return patchedSource.replace(literalNeedle, "n=[{slug:`general-settings`},{slug:`keybinds`},{slug:`appearance`}");
  }

  throw new Error("Required Keybinds settings patch failed: could not add keybinds settings section");
}

function applyKeybindsSettingsSharedPatch(currentSource) {
  let patchedSource = currentSource;

  if (!patchedSource.includes("settings.nav.keybinds")) {
    const navNeedle =
      '"general-settings":{id:`settings.nav.general-settings`,defaultMessage:`General`,description:`Title for general settings section`},';
    const navPatch =
      '"general-settings":{id:`settings.nav.general-settings`,defaultMessage:`General`,description:`Title for general settings section`},keybinds:{id:`settings.nav.keybinds`,defaultMessage:`Keybinds`,description:`Title for keybinds settings section`},';
    if (!patchedSource.includes(navNeedle)) {
      throw new Error("Required Keybinds settings patch failed: could not add keybinds nav label");
    }
    patchedSource = patchedSource.replace(navNeedle, navPatch);
  }

  if (!patchedSource.includes("settings.section.keybinds")) {
    const sectionNeedle =
      "case`general-settings`:{let e;return t[2]===Symbol.for(`react.memo_cache_sentinel`)?(e=(0,d.jsx)(n,{id:`settings.section.general-settings`,defaultMessage:`General`,description:`Title for general settings section`}),t[2]=e):e=t[2],e}";
    const sectionPatch =
      "case`general-settings`:{let e;return t[2]===Symbol.for(`react.memo_cache_sentinel`)?(e=(0,d.jsx)(n,{id:`settings.section.general-settings`,defaultMessage:`General`,description:`Title for general settings section`}),t[2]=e):e=t[2],e}case`keybinds`:{return (0,d.jsx)(n,{id:`settings.section.keybinds`,defaultMessage:`Keybinds`,description:`Title for keybinds settings section`})}";
    if (!patchedSource.includes(sectionNeedle)) {
      throw new Error("Required Keybinds settings patch failed: could not add keybinds section title");
    }
    patchedSource = patchedSource.replace(sectionNeedle, sectionPatch);
  }

  return patchedSource;
}

function applyLinuxKeybindOverridesRuntimePatch(currentSource) {
  const runtimePatch = `;function codexLinuxKeybindOverridesRuntime(){try{if(typeof window=="undefined")return;let storageKey=${JSON.stringify(linuxKeybindOverridesKey)},defaultMap=typeof Ct=="object"&&Ct?Ct:{},overrides={};function loadOverrides(){try{let value=JSON.parse(localStorage.getItem(storageKey)||"{}");overrides=value&&typeof value=="object"&&!Array.isArray(value)?value:{}}catch{overrides={}}}function isShortcutCaptureTarget(event){let target=event.target;return target instanceof Element&&target.closest("[data-codex-keybind-input]")!=null}function normalizeKeyName(key){let map={Space:" ",Esc:"Escape",Up:"ArrowUp",Down:"ArrowDown",Left:"ArrowLeft",Right:"ArrowRight",Plus:"+",Comma:",",Period:".",Slash:"/"};return map[key]??(/^.$/.test(key)?key.toUpperCase():key)}function parseAccelerator(accelerator){if(typeof accelerator!="string"||accelerator.trim().length===0)return null;let isMac=/Mac/.test(navigator.platform||""),parts=accelerator.split("+").map(part=>part.trim()).filter(Boolean),parsed={ctrl:false,alt:false,shift:false,meta:false,key:null};for(let part of parts){switch(part){case"CmdOrCtrl":isMac?parsed.meta=true:parsed.ctrl=true;break;case"Command":case"Cmd":case"Meta":case"Super":case"Win":parsed.meta=true;break;case"Control":case"Ctrl":parsed.ctrl=true;break;case"Alt":case"Option":parsed.alt=true;break;case"Shift":parsed.shift=true;break;default:parsed.key=normalizeKeyName(part);break}}return parsed.key?parsed:null}function matches(event,parsed){return event.ctrlKey===parsed.ctrl&&event.altKey===parsed.alt&&event.shiftKey===parsed.shift&&event.metaKey===parsed.meta&&normalizeKeyName(event.key)===parsed.key}function dispatchHost(message){if(typeof E=="object"&&E&&typeof E.dispatchHostMessage=="function"){E.dispatchHostMessage(message);return true}return false}function dispatchElectron(type,params={}){if(typeof E=="object"&&E&&typeof E.dispatchMessage=="function"){E.dispatchMessage(type,params);return true}return false}let hostActionTypes={newThread:"new-chat",quickChat:"new-quick-chat",newThreadAlt:"new-chat",toggleSidebar:"toggle-sidebar",toggleTerminal:"toggle-terminal",toggleBrowserPanel:"toggle-browser-panel",toggleDiffPanel:"toggle-diff-panel",findInThread:"find-in-thread",navigateBack:"navigate-back",navigateForward:"navigate-forward",previousThread:"previous-thread",nextThread:"next-thread",copyConversationPath:"copy-conversation-path",toggleThreadPin:"toggle-thread-pin",renameThread:"rename-thread",archiveThread:"archive-thread",copyWorkingDirectory:"copy-working-directory",copySessionId:"copy-session-id",copyDeeplink:"copy-deeplink",toggleFileTreePanel:"toggle-file-tree-panel"};function runAction(id){if(/^thread[1-9]$/.test(id))return dispatchHost({type:"go-to-thread-index",index:Number(id.slice(6))-1});switch(id){case"openCommandMenu":case"openCommandMenuAlt":return dispatchHost({type:"command-menu",query:""});case"searchChats":return dispatchHost({type:"chat-search-command-menu"});case"searchFiles":return dispatchHost({type:"file-search-command-menu"});case"openFolder":return dispatchElectron("electron-create-new-workspace-root-option",{});case"settings":return dispatchElectron("show-settings",{section:"general-settings"});case"openBrowserTab":return dispatchHost({type:"browser-sidebar-command",command:{type:"new-tab"}});case"reloadBrowserPage":return dispatchHost({type:"browser-sidebar-command",command:{type:"reload"}});case"hardReloadBrowserPage":return dispatchHost({type:"browser-sidebar-command",command:{type:"hard-reload"}});case"dictation":return dispatchElectron("global-dictation-start",{});default:return hostActionTypes[id]?dispatchHost({type:hostActionTypes[id]}):false}}loadOverrides();window.addEventListener("storage",event=>{event.key===storageKey&&loadOverrides()});window.addEventListener("codex-linux-keybind-overrides-changed",loadOverrides);window.addEventListener("keydown",event=>{if(event.defaultPrevented||event.repeat||isShortcutCaptureTarget(event))return;for(let[id,accelerator]of Object.entries(overrides)){if(typeof accelerator!="string"||accelerator.trim().length===0||accelerator.trim()===(defaultMap[id]||""))continue;let parsed=parseAccelerator(accelerator);if(parsed&&matches(event,parsed)&&runAction(id)){event.preventDefault();event.stopPropagation();break}}},true)}catch{}}codexLinuxKeybindOverridesRuntime();`;

  const runtimeMarker = ";function codexLinuxKeybindOverridesRuntime()";
  const existingRuntimeIndex = currentSource.indexOf(runtimeMarker);
  if (existingRuntimeIndex !== -1) {
    return `${currentSource.slice(0, existingRuntimeIndex).trimEnd()}\n${runtimePatch}`;
  }

  return `${currentSource}\n${runtimePatch}`;
}

function applyKeybindsSettingsIndexPatch(currentSource) {
  let patchedSource = currentSource;

  if (
    !patchedSource.includes("var c_e=") &&
    !patchedSource.includes("Xge=") &&
    !patchedSource.includes("Zge=")
  ) {
    return patchedSource;
  }

  if (!patchedSource.includes(`${keybindsSettingsAsset}`)) {
    const routeNeedle = 'var c_e={"general-settings":';
    const routePatch = `var c_e={keybinds:(0,Z.lazy)(()=>s(()=>import(\`./${keybindsSettingsAsset}\`),[],import.meta.url)),"general-settings":`;
    if (!patchedSource.includes(routeNeedle)) {
      throw new Error("Required Keybinds settings patch failed: could not add keybinds route");
    }
    patchedSource = patchedSource.replace(routeNeedle, routePatch);
  }

  if (!patchedSource.includes("keybinds:xh")) {
    const iconNeedle = 'Xge={"general-settings":xh,';
    const iconPatch = 'Xge={keybinds:xh,"general-settings":xh,';
    if (!patchedSource.includes(iconNeedle)) {
      throw new Error("Required Keybinds settings patch failed: could not add keybinds icon");
    }
    patchedSource = patchedSource.replace(iconNeedle, iconPatch);
  }

  if (!patchedSource.includes("Zge=[`general-settings`,`keybinds`")) {
    const orderNeedle = "Zge=[`general-settings`,`appearance`";
    const orderPatch = "Zge=[`general-settings`,`keybinds`,`appearance`";
    if (!patchedSource.includes(orderNeedle)) {
      throw new Error("Required Keybinds settings patch failed: could not add keybinds nav order");
    }
    patchedSource = patchedSource.replace(orderNeedle, orderPatch);
  }

  if (!patchedSource.includes("slugs:[`general-settings`,`keybinds`")) {
    const groupNeedle = "slugs:[`general-settings`,`appearance`,`connections`,`git-settings`,`usage`]";
    const groupPatch = "slugs:[`general-settings`,`keybinds`,`appearance`,`connections`,`git-settings`,`usage`]";
    if (!patchedSource.includes(groupNeedle)) {
      throw new Error("Required Keybinds settings patch failed: could not add keybinds nav group");
    }
    patchedSource = patchedSource.replace(groupNeedle, groupPatch);
  }

  if (!patchedSource.includes("case`keybinds`:return l===`electron`")) {
    const visibilityNeedle =
      "case`appearance`:case`git-settings`:case`worktrees`:case`local-environments`:case`data-controls`:case`environments`:return l===`electron`;";
    const visibilityPatch =
      "case`keybinds`:return l===`electron`;case`appearance`:case`git-settings`:case`worktrees`:case`local-environments`:case`data-controls`:case`environments`:return l===`electron`;";
    if (!patchedSource.includes(visibilityNeedle)) {
      throw new Error("Required Keybinds settings patch failed: could not add keybinds visibility");
    }
    patchedSource = patchedSource.replace(visibilityNeedle, visibilityPatch);
  }

  if (!patchedSource.includes("case`keybinds`:k=!1;break bb0;")) {
    const redirectNeedle =
      "case`appearance`:case`general-settings`:case`agent`:case`git-settings`:case`account`:case`data-controls`:case`personalization`:k=!1;break bb0;";
    const redirectPatch =
      "case`keybinds`:k=!1;break bb0;case`appearance`:case`general-settings`:case`agent`:case`git-settings`:case`account`:case`data-controls`:case`personalization`:k=!1;break bb0;";
    if (patchedSource.includes(redirectNeedle)) {
      patchedSource = patchedSource.replace(redirectNeedle, redirectPatch);
    }
  }

  return applyLinuxKeybindOverridesRuntimePatch(patchedSource);
}

function applyLinuxSettingsPersistencePatch(currentSource) {
  let patchedSource = currentSource;

  if (
    !patchedSource.includes('"set-global-state"') &&
    !patchedSource.includes("var Yb=`.codex-global-state.json`;")
  ) {
    return patchedSource;
  }

  if (!patchedSource.includes("function codexLinuxPersistSettingsState(")) {
    const stateFileNeedle = "var Yb=`.codex-global-state.json`;";
    const stateFilePatch =
      `var Yb=\`.codex-global-state.json\`;function codexLinuxSettingsPath(){let e=process.env.XDG_CONFIG_HOME||process.env.HOME&&i.join(process.env.HOME,\`.config\`);return e?i.join(e,\`codex-desktop\`,\`settings.json\`):null}function codexLinuxReadSettingsFile(){let e=codexLinuxSettingsPath();if(!e||!o.existsSync(e))return{};try{let t=o.readFileSync(e,\`utf8\`),n=JSON.parse(t);return n&&typeof n===\`object\`&&!Array.isArray(n)?n:{}}catch(e){return{}}}function codexLinuxPersistSettingsState(e,t){if(process.platform!==\`linux\`||![${Object.values(linuxSettingsKeys).map((key) => `\`${key}\``).join(",")}].includes(e))return;try{let n=codexLinuxSettingsPath();if(!n)return;let r=codexLinuxReadSettingsFile();t===void 0?delete r[e]:r[e]=t,o.mkdirSync(i.dirname(n),{recursive:!0,mode:448}),o.writeFileSync(n,JSON.stringify(r,null,2)+\`\\n\`,\`utf8\`)}catch(e){}}`;
    if (!patchedSource.includes(stateFileNeedle)) {
      throw new Error("Required Linux settings patch failed: could not add settings persistence helpers");
    }
    patchedSource = patchedSource.replace(stateFileNeedle, stateFilePatch);
  }

  const setGlobalStateNeedle =
    '"set-global-state":async({key:t,value:n,origin:r})=>(this.globalState.set(t,n),t===e.Tt.REMOTE_PROJECTS&&r.send(H,{type:`workspace-root-options-updated`}),{success:!0})';
  const setGlobalStatePatch =
    '"set-global-state":async({key:t,value:n,origin:r})=>(this.globalState.set(t,n),codexLinuxPersistSettingsState(t,n),t===e.Tt.REMOTE_PROJECTS&&r.send(H,{type:`workspace-root-options-updated`}),{success:!0})';
  if (patchedSource.includes(setGlobalStatePatch)) {
    return patchedSource;
  }
  if (!patchedSource.includes(setGlobalStateNeedle)) {
    throw new Error("Required Linux settings patch failed: could not synchronize launcher settings");
  }

  return patchedSource.replace(setGlobalStateNeedle, setGlobalStatePatch);
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
    console.warn(
      "WARN: Could not find Linux opaque window default insertion point — skipping settings default patch",
    );
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

function requireName(source, moduleName) {
  const escaped = moduleName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = source.match(new RegExp(`([A-Za-z_$][\\w$]*)=require\\(\`${escaped}\`\\)`));
  return match?.[1] ?? null;
}

function findCallBlock(source, marker) {
  const markerStart = source.indexOf(marker);
  if (markerStart === -1) {
    return null;
  }

  const blockStart = Math.max(
    source.lastIndexOf("var ", markerStart),
    source.lastIndexOf("let ", markerStart),
    source.lastIndexOf("const ", markerStart),
  );
  const blockEnd = source.indexOf("});", markerStart);
  if (blockStart === -1 || blockEnd === -1) {
    return null;
  }

  return {
    start: blockStart,
    end: blockEnd + "});".length,
    text: source.slice(blockStart, blockEnd + "});".length),
  };
}

function applyLinuxFileManagerPatch(currentSource) {
  const block = findCallBlock(currentSource, "id:`fileManager`");
  if (block == null) {
    console.error("Failed to apply Linux File Manager Patch");
    return currentSource;
  }

  if (block.text.includes("linux:{")) {
    return currentSource;
  }

  const electronVar = requireName(currentSource, "electron");
  const fsVar = requireName(currentSource, "node:fs");
  const pathVar = requireName(currentSource, "node:path");
  if (electronVar == null || fsVar == null || pathVar == null) {
    console.error("Failed to apply Linux File Manager Patch");
    return currentSource;
  }

  const insertionPoint = block.text.lastIndexOf("}});");
  if (insertionPoint === -1) {
    console.error("Failed to apply Linux File Manager Patch");
    return currentSource;
  }

  const linuxFileManager =
    `,linux:{label:\`File Manager\`,icon:\`apps/file-explorer.png\`,detect:()=>\`linux-file-manager\`,args:e=>[e],open:async({path:e})=>{let __codexResolved=e;for(;;){if((0,${fsVar}.existsSync)(__codexResolved))break;let __codexParent=(0,${pathVar}.dirname)(__codexResolved);if(__codexParent===__codexResolved){__codexResolved=null;break}__codexResolved=__codexParent}let __codexOpenTarget=__codexResolved??e;if((0,${fsVar}.existsSync)(__codexOpenTarget)&&(0,${fsVar}.statSync)(__codexOpenTarget).isFile())__codexOpenTarget=(0,${pathVar}.dirname)(__codexOpenTarget);let __codexError=await ${electronVar}.shell.openPath(__codexOpenTarget);if(__codexError)throw Error(__codexError)}}`;

  const patchedBlock =
    block.text.slice(0, insertionPoint + 1) +
    linuxFileManager +
    block.text.slice(insertionPoint + 1);
  const patchedSource =
    currentSource.slice(0, block.start) + patchedBlock + currentSource.slice(block.end);

  const patchedBlockCheck = patchedSource.slice(block.start, block.start + patchedBlock.length);
  if (
    !patchedBlockCheck.includes("linux:{label:`File Manager`") ||
    !patchedBlockCheck.includes("detect:()=>`linux-file-manager`") ||
    !patchedBlockCheck.includes(`${electronVar}.shell.openPath(__codexOpenTarget)`)
  ) {
    console.error("Failed to apply Linux File Manager Patch");
    return currentSource;
  }

  return patchedSource;
}

function applyLinuxWindowOptionsPatch(currentSource, iconAsset) {
  if (iconAsset == null) {
    return currentSource;
  }

  const windowOptionsNeedle = "...process.platform===`win32`?{autoHideMenuBar:!0}:{},";
  const iconPathExpression = `process.resourcesPath+\`/../content/webview/assets/${iconAsset}\``;
  const iconPathNeedle = `icon:${iconPathExpression}`;
  const windowOptionsReplacement =
    `...process.platform===\`win32\`||process.platform===\`linux\`?{autoHideMenuBar:!0,...process.platform===\`linux\`?{${iconPathNeedle}}:{}}:{},`;

  if (currentSource.includes(iconPathNeedle)) {
    return currentSource;
  }

  if (currentSource.includes(windowOptionsNeedle)) {
    return currentSource.replace(windowOptionsNeedle, windowOptionsReplacement);
  }

  console.warn("WARN: Could not find BrowserWindow autoHideMenuBar snippet — skipping window options patch");
  return currentSource;
}

function applyLinuxMenuPatch(currentSource) {
  const menuRegex = /process\.platform===`win32`&&([A-Za-z_$][\w$]*)\.removeMenu\(\),/g;
  let patchedAny = false;
  const patchedSource = currentSource.replace(menuRegex, (match, windowVar) => {
    const linuxPatch = `process.platform===\`linux\`&&${windowVar}.setMenuBarVisibility(!1),`;
    if (currentSource.includes(`${linuxPatch}${match}`)) {
      return match;
    }
    patchedAny = true;
    return `${linuxPatch}${match}`;
  });

  if (!patchedAny && menuRegex.test(currentSource) && !currentSource.includes("setMenuBarVisibility(!1),process.platform===`win32`")) {
    console.warn("WARN: Could not find window menu visibility snippet — skipping menu patch");
  }

  return patchedSource;
}

function applyLinuxSetIconPatch(currentSource, iconAsset) {
  if (iconAsset == null) {
    return currentSource;
  }

  const iconPathExpression = `process.resourcesPath+\`/../content/webview/assets/${iconAsset}\``;
  if (currentSource.includes(`setIcon(${iconPathExpression})`)) {
    return currentSource;
  }

  const readyRegex = /([A-Za-z_$][\w$]*)\.once\(`ready-to-show`,\(\)=>\{/;
  const match = currentSource.match(readyRegex);
  if (match == null) {
    console.warn("WARN: Could not find window setIcon insertion point — skipping setIcon patch");
    return currentSource;
  }

  const windowVar = match[1];
  return currentSource.replace(
    readyRegex,
    `process.platform===\`linux\`&&${windowVar}.setIcon(${iconPathExpression}),${match[0]}`,
  );
}

function applyLinuxOpaqueBackgroundPatch(currentSource) {
  if (currentSource.includes("process.platform===`linux`&&!gw(")) {
    return currentSource;
  }

  const colorConstRegex =
    /([A-Za-z_$][\w$]*)=`#00000000`,([A-Za-z_$][\w$]*)=`#000000`,([A-Za-z_$][\w$]*)=`#f9f9f9`/;
  const colorMatch = currentSource.match(colorConstRegex);

  if (!colorMatch) {
    console.warn(
      "WARN: Could not find color constants (#00000000, #000000, #f9f9f9) — skipping background patch",
    );
    return currentSource;
  }

  const [, transparentVar, darkVar, lightVar] = colorMatch;
  const funcParamRegex =
    /prefersDarkColors:([A-Za-z_$][\w$]*)\}\)\{return\s*([A-Za-z_$][\w$]*)===`win32`/;
  const funcMatch = currentSource.match(funcParamRegex);

  if (funcMatch == null) {
    console.warn("WARN: Could not find prefersDarkColors parameter — skipping background patch");
    return currentSource;
  }

  const darkColorsParam = funcMatch[1];
  const bgNeedle =
    `backgroundMaterial:\`mica\`}:{backgroundColor:${transparentVar},backgroundMaterial:null}}`;
  const oldLinuxBgPatch =
    `backgroundMaterial:\`mica\`}:process.platform===\`linux\`?{backgroundColor:${darkColorsParam}?${darkVar}:${lightVar},backgroundMaterial:null}:{backgroundColor:${transparentVar},backgroundMaterial:null}}`;
  const bgReplacement =
    `backgroundMaterial:\`mica\`}:process.platform===\`linux\`&&!gw(t)?{backgroundColor:${darkColorsParam}?${darkVar}:${lightVar},backgroundMaterial:null}:{backgroundColor:${transparentVar},backgroundMaterial:null}}`;

  if (currentSource.includes(bgNeedle)) {
    return currentSource.replace(bgNeedle, bgReplacement);
  }
  if (currentSource.includes(oldLinuxBgPatch)) {
    return currentSource.replace(oldLinuxBgPatch, bgReplacement);
  }

  console.warn("WARN: Could not find BrowserWindow background color needle — skipping background patch");
  return currentSource;
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

  if (iconPathExpression != null) {
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
  const previousTrayStartupPatch = "(E||process.platform===`linux`)&&oe();";
  const trayStartupPatch = "(E||process.platform===`linux`&&codexLinuxIsTrayEnabled())&&oe();";
  if (patchedSource.includes(trayStartupPatch)) {
    // Already patched.
  } else if (patchedSource.includes(previousTrayStartupPatch)) {
    patchedSource = patchedSource.replace(previousTrayStartupPatch, trayStartupPatch);
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

function applyBrowserAnnotationScreenshotPatch(currentSource) {
  let patchedSource = currentSource;

  const liveElementScreenshotNeedle =
    "if(M&&j?.anchor.kind===`element`){let e=qu(j,y.current)??null,t=e==null?null:rd(e);he=t?.rect??md(j.anchor),_e=t?.borderRadius}";
  const storedAnchorScreenshotPatch =
    "if(M&&j?.anchor.kind===`element`){he=md(j.anchor),_e=void 0}";
  if (patchedSource.includes(storedAnchorScreenshotPatch)) {
    // Already patched.
  } else if (patchedSource.includes(liveElementScreenshotNeedle)) {
    patchedSource = patchedSource.replace(liveElementScreenshotNeedle, storedAnchorScreenshotPatch);
  } else {
    console.warn("WARN: Could not find browser annotation screenshot element highlight — skipping screenshot anchor patch");
  }

  const allMarkersInScreenshotNeedle =
    "de=u?.target.mode===`create`?ce.find(e=>Sd(e.anchor,u.anchor.value))??null:null,fe=!M&&de!=null?ce.filter(e=>e.id!==de.id):ce,";
  const selectedMarkerInScreenshotPatch =
    "de=u?.target.mode===`create`?ce.find(e=>Sd(e.anchor,u.anchor.value))??null:null,fe=M?ue:!M&&de!=null?ce.filter(e=>e.id!==de.id):ce,";
  if (patchedSource.includes(selectedMarkerInScreenshotPatch)) {
    // Already patched.
  } else if (patchedSource.includes(allMarkersInScreenshotNeedle)) {
    patchedSource = patchedSource.replace(allMarkersInScreenshotNeedle, selectedMarkerInScreenshotPatch);
  } else {
    console.warn("WARN: Could not find browser annotation screenshot markers — skipping screenshot marker patch");
  }

  return patchedSource;
}

function applyLinuxTrayCloseSettingPatch(currentSource) {
  let patchedSource = currentSource;

  const closeGateNeedle = "canHideLastLocalWindowToTray:()=>O,disposables:k";
  const closeGatePatch =
    `canHideLastLocalWindowToTray:()=>O&&(process.platform!==\`linux\`||M.globalState.get(\`${linuxSettingsKeys.systemTray}\`)!==!1),disposables:k`;

  if (patchedSource.includes(closeGatePatch)) {
    return patchedSource;
  }

  if (patchedSource.includes(closeGateNeedle)) {
    return patchedSource.replace(closeGateNeedle, closeGatePatch);
  }

  if (patchedSource.includes("canHideLastLocalWindowToTray") && patchedSource.includes("Launching app")) {
    throw new Error("Required Linux tray settings patch failed: could not gate close-to-tray behavior");
  }

  return patchedSource;
}

function applyLinuxLaunchActionArgsPatch(currentSource) {
  let patchedSource = currentSource;

  const launchActionNeedle =
    "let codexLinuxSecondInstanceHandler=(e,t)=>{R.deepLinks.queueProcessArgs(t)||ie()};process.platform===`linux`&&(n.app.on(`second-instance`,codexLinuxSecondInstanceHandler),k.add(()=>{n.app.off(`second-instance`,codexLinuxSecondInstanceHandler)})),l(e=>{R.deepLinks.queueProcessArgs(e)||ie()});let ae=async(e,t)=>{P.hotkeyWindowLifecycleManager.hide();let n=P.getPrimaryWindow(z),r=n??await P.createFreshLocalWindow(e);r!=null&&(n!=null&&t.navigateExistingWindow&&R.navigateToRoute(r,e),re(r))},oe=async()=>{";
  const oldLaunchActionPatch =
    "let ae=async(e,t)=>{P.hotkeyWindowLifecycleManager.hide();let n=P.getPrimaryWindow(z),r=n??await P.createFreshLocalWindow(e);r!=null&&(n!=null&&t.navigateExistingWindow&&R.navigateToRoute(r,e),re(r))},codexLinuxOpenQuickChat=async()=>{P.hotkeyWindowLifecycleManager.hide();let e=P.getPrimaryWindow(z),t=e??await P.createFreshLocalWindow(`/`);t!=null&&(P.windowManager.sendMessageToWindow(t,{type:`new-quick-chat`}),re(t))},codexLinuxHandleLaunchActionArgs=async e=>Array.isArray(e)&&e.includes(`--quick-chat`)?(await codexLinuxOpenQuickChat(),!0):Array.isArray(e)&&e.includes(`--new-chat`)?(await ae(`/`,{navigateExistingWindow:!0}),!0):!1,codexLinuxHandleLaunchActionArgsFallback=(e,t)=>{codexLinuxHandleLaunchActionArgs(e).then(e=>{e||t()}).catch(e=>{g.reportNonFatal(e instanceof Error?e:`Failed to handle Linux launch action`,{kind:`linux-launch-action-failed`}),t()})},codexLinuxSecondInstanceHandler=(e,t)=>{codexLinuxHandleLaunchActionArgsFallback(t,()=>{R.deepLinks.queueProcessArgs(t)||ie()})};process.platform===`linux`&&(n.app.on(`second-instance`,codexLinuxSecondInstanceHandler),k.add(()=>{n.app.off(`second-instance`,codexLinuxSecondInstanceHandler)})),l(e=>{codexLinuxHandleLaunchActionArgsFallback(e,()=>{R.deepLinks.queueProcessArgs(e)||ie()})});let oe=async()=>{";
  const deepLinkFirstLaunchActionPatch =
    "let ae=async(e,t)=>{P.hotkeyWindowLifecycleManager.hide();let n=P.getPrimaryWindow(z),r=n??await P.createFreshLocalWindow(e);r!=null&&(n!=null&&t.navigateExistingWindow&&R.navigateToRoute(r,e),re(r))},codexLinuxOpenQuickChat=async()=>{P.hotkeyWindowLifecycleManager.hide();let e=P.getPrimaryWindow(z),t=e??await P.createFreshLocalWindow(`/`);t!=null&&(P.windowManager.sendMessageToWindow(t,{type:`new-quick-chat`}),re(t))},codexLinuxHandleLaunchActionArgs=async e=>Array.isArray(e)&&R.deepLinks.queueProcessArgs(e)?!0:Array.isArray(e)&&e.includes(`--quick-chat`)?(await codexLinuxOpenQuickChat(),!0):Array.isArray(e)&&e.includes(`--new-chat`)?(await ae(`/`,{navigateExistingWindow:!0}),!0):!1,codexLinuxHandleLaunchActionArgsFallback=(e,t)=>{codexLinuxHandleLaunchActionArgs(e).then(e=>{e||t()}).catch(e=>{g.reportNonFatal(e instanceof Error?e:`Failed to handle Linux launch action`,{kind:`linux-launch-action-failed`}),t()})},codexLinuxSecondInstanceHandler=(e,t)=>{codexLinuxHandleLaunchActionArgsFallback(t,()=>{ie()})};process.platform===`linux`&&(n.app.on(`second-instance`,codexLinuxSecondInstanceHandler),k.add(()=>{n.app.off(`second-instance`,codexLinuxSecondInstanceHandler)})),l(e=>{codexLinuxHandleLaunchActionArgsFallback(e,()=>{ie()})});let oe=async()=>{";
  const deepLinkAwareExistingWindowLaunchActionPatch =
    "let ae=async(e,t)=>{P.hotkeyWindowLifecycleManager.hide();let n=P.getPrimaryWindow(z),r=n??await P.createFreshLocalWindow(e);r!=null&&(n!=null&&t.navigateExistingWindow&&R.navigateToRoute(r,e),re(r))},codexLinuxOpenQuickChat=async()=>{P.hotkeyWindowLifecycleManager.hide();let e=P.getPrimaryWindow(z),t=e??await P.createFreshLocalWindow(`/`);t!=null&&(P.windowManager.sendMessageToWindow(t,{type:`new-quick-chat`}),re(t))},codexLinuxHasDeepLink=e=>Array.isArray(e)&&e.some(e=>typeof e===`string`&&(e.startsWith(`codex://`)||e.startsWith(`codex-browser-sidebar://`))),codexLinuxHandleLaunchActionArgs=async e=>codexLinuxHasDeepLink(e)&&R.deepLinks.queueProcessArgs(e)?!0:Array.isArray(e)&&e.includes(`--quick-chat`)?(await codexLinuxOpenQuickChat(),!0):Array.isArray(e)&&e.includes(`--new-chat`)?(await ae(`/`,{navigateExistingWindow:!0}),!0):!1,codexLinuxHandleLaunchActionArgsFallback=(e,t)=>{codexLinuxHandleLaunchActionArgs(e).then(e=>{e||t()}).catch(e=>{g.reportNonFatal(e instanceof Error?e:`Failed to handle Linux launch action`,{kind:`linux-launch-action-failed`}),t()})},codexLinuxSecondInstanceHandler=(e,t)=>{codexLinuxHandleLaunchActionArgsFallback(t,()=>{ie()})};process.platform===`linux`&&(n.app.on(`second-instance`,codexLinuxSecondInstanceHandler),k.add(()=>{n.app.off(`second-instance`,codexLinuxSecondInstanceHandler)})),l(e=>{codexLinuxHandleLaunchActionArgsFallback(e,()=>{ie()})});let oe=async()=>{";
  const openHomeHotkeyWindowLaunchActionPatch =
    "let ae=async(e,t)=>{P.hotkeyWindowLifecycleManager.hide();let n=P.getPrimaryWindow(z),r=n??await P.createFreshLocalWindow(e);r!=null&&(n!=null&&t.navigateExistingWindow&&R.navigateToRoute(r,e),re(r))},codexLinuxShowHotkeyWindow=async()=>{let e=P.hotkeyWindowLifecycleManager;typeof e.openHome===`function`?await e.openHome():typeof e.show===`function`?await e.show():await P.ensureHostWindow(z)},codexLinuxOpenQuickChat=async()=>{P.hotkeyWindowLifecycleManager.hide();let e=P.getPrimaryWindow(z),t=e??await P.createFreshLocalWindow(`/`);t!=null&&(P.windowManager.sendMessageToWindow(t,{type:`new-quick-chat`}),re(t))},codexLinuxHasDeepLink=e=>Array.isArray(e)&&e.some(e=>typeof e===`string`&&(e.startsWith(`codex://`)||e.startsWith(`codex-browser-sidebar://`))),codexLinuxHandleLaunchActionArgs=async e=>codexLinuxHasDeepLink(e)&&R.deepLinks.queueProcessArgs(e)?!0:Array.isArray(e)&&(e.includes(`--prompt-chat`)||e.includes(`--hotkey-window`))?(await codexLinuxShowHotkeyWindow(),!0):Array.isArray(e)&&e.includes(`--quick-chat`)?(await codexLinuxOpenQuickChat(),!0):Array.isArray(e)&&e.includes(`--new-chat`)?(await ae(`/`,{navigateExistingWindow:!0}),!0):!1,codexLinuxHandleLaunchActionArgsFallback=(e,t)=>{codexLinuxHandleLaunchActionArgs(e).then(e=>{e||t()}).catch(e=>{g.reportNonFatal(e instanceof Error?e:`Failed to handle Linux launch action`,{kind:`linux-launch-action-failed`}),t()})},codexLinuxSecondInstanceHandler=(e,t)=>{codexLinuxHandleLaunchActionArgsFallback(t,()=>{ie()})};process.platform===`linux`&&(n.app.on(`second-instance`,codexLinuxSecondInstanceHandler),k.add(()=>{n.app.off(`second-instance`,codexLinuxSecondInstanceHandler)})),l(e=>{codexLinuxHandleLaunchActionArgsFallback(e,()=>{ie()})});let oe=async()=>{";
  const socketHotkeyWindowLaunchActionPatch =
    "let ae=async(e,t)=>{P.hotkeyWindowLifecycleManager.hide();let n=P.getPrimaryWindow(z),r=n??await P.createFreshLocalWindow(e);r!=null&&(n!=null&&t.navigateExistingWindow&&R.navigateToRoute(r,e),re(r))},codexLinuxShowHotkeyWindow=async()=>{let e=P.hotkeyWindowLifecycleManager;typeof e.openHome===`function`?await e.openHome():typeof e.show===`function`?await e.show():await P.ensureHostWindow(z)},codexLinuxOpenQuickChat=async()=>{P.hotkeyWindowLifecycleManager.hide();let e=P.getPrimaryWindow(z),t=e??await P.createFreshLocalWindow(`/`);t!=null&&(P.windowManager.sendMessageToWindow(t,{type:`new-quick-chat`}),re(t))},codexLinuxHasDeepLink=e=>Array.isArray(e)&&e.some(e=>typeof e===`string`&&(e.startsWith(`codex://`)||e.startsWith(`codex-browser-sidebar://`))),codexLinuxHandleLaunchActionArgs=async e=>codexLinuxHasDeepLink(e)&&R.deepLinks.queueProcessArgs(e)?!0:Array.isArray(e)&&(e.includes(`--prompt-chat`)||e.includes(`--hotkey-window`))?(await codexLinuxShowHotkeyWindow(),!0):Array.isArray(e)&&e.includes(`--quick-chat`)?(await codexLinuxOpenQuickChat(),!0):Array.isArray(e)&&e.includes(`--new-chat`)?(await ae(`/`,{navigateExistingWindow:!0}),!0):!1,codexLinuxHandleLaunchActionArgsFallback=(e,t)=>{codexLinuxHandleLaunchActionArgs(e).then(e=>{e||t()}).catch(e=>{g.reportNonFatal(e instanceof Error?e:`Failed to handle Linux launch action`,{kind:`linux-launch-action-failed`}),t()})},codexLinuxStartLaunchActionSocket=()=>{let e=process.env.CODEX_DESKTOP_LAUNCH_ACTION_SOCKET?.trim();if(process.platform!==`linux`||!e)return;try{o.mkdirSync(i.default.dirname(e),{recursive:!0,mode:448}),o.rmSync(e,{force:!0});let t=u.default.createServer(t=>{let n=``,r=!1,i=()=>{if(r)return;r=!0;let i=[];try{let e=JSON.parse(n.trim());Array.isArray(e.argv)&&(i=e.argv.filter(e=>typeof e===`string`))}catch(e){t.end?.(`error\\n`);return}codexLinuxHandleLaunchActionArgs(i).then(e=>e?void 0:ie()).then(()=>{t.end?.(`ok\\n`)}).catch(e=>{g.reportNonFatal(e instanceof Error?e:`Failed to handle Linux launch action socket`,{kind:`linux-launch-action-socket-failed`}),t.end?.(`error\\n`)})};t.setEncoding?.(`utf8`),t.on(`data`,e=>{n+=e,n.includes(`\\n`)?i():n.length>65536&&t.destroy()}),t.on(`end`,i)});t.on(`error`,e=>{g.reportNonFatal(e instanceof Error?e:`Failed Linux launch action socket`,{kind:`linux-launch-action-socket-error`})}),t.listen(e),k.add(()=>{t.close(),o.rmSync(e,{force:!0})})}catch(e){g.reportNonFatal(e instanceof Error?e:`Failed to start Linux launch action socket`,{kind:`linux-launch-action-socket-start-failed`})}},codexLinuxSecondInstanceHandler=(e,t)=>{codexLinuxHandleLaunchActionArgsFallback(t,()=>{ie()})};process.platform===`linux`&&(codexLinuxStartLaunchActionSocket(),n.app.on(`second-instance`,codexLinuxSecondInstanceHandler),k.add(()=>{n.app.off(`second-instance`,codexLinuxSecondInstanceHandler)})),l(e=>{codexLinuxHandleLaunchActionArgsFallback(e,()=>{ie()})});let oe=async()=>{";
  const hotkeyWindowLaunchActionPatch = socketHotkeyWindowLaunchActionPatch
    .replace(
      "let ae=async(e,t)=>{",
      `let codexLinuxGetSetting=e=>process.platform!==\`linux\`||M.globalState.get(e)!==!1,codexLinuxIsTrayEnabled=()=>codexLinuxGetSetting(\`${linuxSettingsKeys.systemTray}\`),codexLinuxIsWarmStartEnabled=()=>codexLinuxGetSetting(\`${linuxSettingsKeys.warmStart}\`),codexLinuxIsPromptWindowEnabled=()=>codexLinuxGetSetting(\`${linuxSettingsKeys.promptWindow}\`),ae=async(e,t)=>{`,
    )
    .replace(
      "codexLinuxShowHotkeyWindow=async()=>{let e=P.hotkeyWindowLifecycleManager;typeof e.openHome===`function`?await e.openHome():typeof e.show===`function`?await e.show():await P.ensureHostWindow(z)}",
      "codexLinuxGetHotkeyWindowController=()=>typeof P.hotkeyWindowLifecycleManager.ensureHotkeyWindowController===`function`?P.hotkeyWindowLifecycleManager.ensureHotkeyWindowController():P.hotkeyWindowLifecycleManager,codexLinuxShowHotkeyWindow=async()=>{let e=codexLinuxGetHotkeyWindowController();typeof e.openHome===`function`?await e.openHome():typeof e.show===`function`?await e.show():await P.ensureHostWindow(z)}",
    )
    .replace(
      "Array.isArray(e)&&(e.includes(`--prompt-chat`)||e.includes(`--hotkey-window`))?(await codexLinuxShowHotkeyWindow(),!0)",
      "Array.isArray(e)&&(e.includes(`--prompt-chat`)||e.includes(`--hotkey-window`))?(codexLinuxIsPromptWindowEnabled()?(await codexLinuxShowHotkeyWindow(),!0):!1)",
    )
    .replace(
      "if(process.platform!==`linux`||!e)return;",
      "if(process.platform!==`linux`||!e||!codexLinuxIsWarmStartEnabled())return;",
    )
    .replace(
      "codexLinuxStartLaunchActionSocket=()=>{",
      "codexLinuxPrewarmHotkeyWindow=()=>{try{let e=codexLinuxGetHotkeyWindowController();typeof e.prewarm===`function`&&e.prewarm()}catch(e){g.reportNonFatal(e instanceof Error?e:`Failed to prewarm Linux hotkey window`,{kind:`linux-hotkey-window-prewarm-failed`})}},codexLinuxStartLaunchActionSocket=()=>{",
    )
    .replace(
      "codexLinuxPrewarmHotkeyWindow=()=>{try{",
      "codexLinuxPrewarmHotkeyWindow=()=>{if(!codexLinuxIsPromptWindowEnabled())return;try{",
    );
  const showBasedHotkeyWindowLaunchActionPatch =
    "let ae=async(e,t)=>{P.hotkeyWindowLifecycleManager.hide();let n=P.getPrimaryWindow(z),r=n??await P.createFreshLocalWindow(e);r!=null&&(n!=null&&t.navigateExistingWindow&&R.navigateToRoute(r,e),re(r))},codexLinuxShowHotkeyWindow=async()=>{P.hotkeyWindowLifecycleManager.show()||await P.ensureHostWindow(z)},codexLinuxOpenQuickChat=async()=>{P.hotkeyWindowLifecycleManager.hide();let e=P.getPrimaryWindow(z),t=e??await P.createFreshLocalWindow(`/`);t!=null&&(P.windowManager.sendMessageToWindow(t,{type:`new-quick-chat`}),re(t))},codexLinuxHasDeepLink=e=>Array.isArray(e)&&e.some(e=>typeof e===`string`&&(e.startsWith(`codex://`)||e.startsWith(`codex-browser-sidebar://`))),codexLinuxHandleLaunchActionArgs=async e=>codexLinuxHasDeepLink(e)&&R.deepLinks.queueProcessArgs(e)?!0:Array.isArray(e)&&(e.includes(`--prompt-chat`)||e.includes(`--hotkey-window`))?(await codexLinuxShowHotkeyWindow(),!0):Array.isArray(e)&&e.includes(`--quick-chat`)?(await codexLinuxOpenQuickChat(),!0):Array.isArray(e)&&e.includes(`--new-chat`)?(await ae(`/`,{navigateExistingWindow:!0}),!0):!1,codexLinuxHandleLaunchActionArgsFallback=(e,t)=>{codexLinuxHandleLaunchActionArgs(e).then(e=>{e||t()}).catch(e=>{g.reportNonFatal(e instanceof Error?e:`Failed to handle Linux launch action`,{kind:`linux-launch-action-failed`}),t()})},codexLinuxSecondInstanceHandler=(e,t)=>{codexLinuxHandleLaunchActionArgsFallback(t,()=>{ie()})};process.platform===`linux`&&(n.app.on(`second-instance`,codexLinuxSecondInstanceHandler),k.add(()=>{n.app.off(`second-instance`,codexLinuxSecondInstanceHandler)})),l(e=>{codexLinuxHandleLaunchActionArgsFallback(e,()=>{ie()})});let oe=async()=>{";
  const freshWindowLaunchActionPatch =
    "let ae=async(e,t)=>{P.hotkeyWindowLifecycleManager.hide();let n=P.getPrimaryWindow(z),r=n??await P.createFreshLocalWindow(e);r!=null&&(n!=null&&t.navigateExistingWindow&&R.navigateToRoute(r,e),re(r))},codexLinuxOpenNewChat=async()=>{P.hotkeyWindowLifecycleManager.hide();let e=await P.createFreshLocalWindow(`/`);e!=null&&re(e)},codexLinuxOpenQuickChat=async()=>{P.hotkeyWindowLifecycleManager.hide();let e=await P.createFreshLocalWindow(`/`);e!=null&&(P.windowManager.sendMessageToWindow(e,{type:`new-quick-chat`}),re(e))},codexLinuxHasDeepLink=e=>Array.isArray(e)&&e.some(e=>typeof e===`string`&&(e.startsWith(`codex://`)||e.startsWith(`codex-browser-sidebar://`))),codexLinuxHandleLaunchActionArgs=async e=>codexLinuxHasDeepLink(e)&&R.deepLinks.queueProcessArgs(e)?!0:Array.isArray(e)&&e.includes(`--quick-chat`)?(await codexLinuxOpenQuickChat(),!0):Array.isArray(e)&&e.includes(`--new-chat`)?(await codexLinuxOpenNewChat(),!0):!1,codexLinuxHandleLaunchActionArgsFallback=(e,t)=>{codexLinuxHandleLaunchActionArgs(e).then(e=>{e||t()}).catch(e=>{g.reportNonFatal(e instanceof Error?e:`Failed to handle Linux launch action`,{kind:`linux-launch-action-failed`}),t()})},codexLinuxSecondInstanceHandler=(e,t)=>{codexLinuxHandleLaunchActionArgsFallback(t,()=>{ie()})};process.platform===`linux`&&(n.app.on(`second-instance`,codexLinuxSecondInstanceHandler),k.add(()=>{n.app.off(`second-instance`,codexLinuxSecondInstanceHandler)})),l(e=>{codexLinuxHandleLaunchActionArgsFallback(e,()=>{ie()})});let oe=async()=>{";
  const launchActionPatch =
    hotkeyWindowLaunchActionPatch;

  if (
    patchedSource.includes("codexLinuxGetSetting=e=>") &&
    patchedSource.includes("codexLinuxGetHotkeyWindowController=()=>") &&
    patchedSource.includes("codexLinuxPrewarmHotkeyWindow=()=>") &&
    patchedSource.includes("codexLinuxStartLaunchActionSocket=()=>") &&
    !patchedSource.includes("codexLinuxOpenNewChat")
  ) {
    return patchedSource;
  }

  if (patchedSource.includes(oldLaunchActionPatch)) {
    patchedSource = patchedSource.replace(oldLaunchActionPatch, launchActionPatch);
  } else if (patchedSource.includes(deepLinkFirstLaunchActionPatch)) {
    patchedSource = patchedSource.replace(deepLinkFirstLaunchActionPatch, launchActionPatch);
  } else if (patchedSource.includes(deepLinkAwareExistingWindowLaunchActionPatch)) {
    patchedSource = patchedSource.replace(deepLinkAwareExistingWindowLaunchActionPatch, launchActionPatch);
  } else if (patchedSource.includes(openHomeHotkeyWindowLaunchActionPatch)) {
    patchedSource = patchedSource.replace(openHomeHotkeyWindowLaunchActionPatch, launchActionPatch);
  } else if (patchedSource.includes(socketHotkeyWindowLaunchActionPatch)) {
    patchedSource = patchedSource.replace(socketHotkeyWindowLaunchActionPatch, launchActionPatch);
  } else if (patchedSource.includes(showBasedHotkeyWindowLaunchActionPatch)) {
    patchedSource = patchedSource.replace(showBasedHotkeyWindowLaunchActionPatch, launchActionPatch);
  } else if (patchedSource.includes(freshWindowLaunchActionPatch)) {
    patchedSource = patchedSource.replace(freshWindowLaunchActionPatch, launchActionPatch);
  } else if (patchedSource.includes(launchActionNeedle)) {
    patchedSource = patchedSource.replace(launchActionNeedle, launchActionPatch);
  } else {
    const existingLinuxLaunchActionBlock = patchedSource.match(
      /let ae=async\(e,t\)=>\{P\.hotkeyWindowLifecycleManager\.hide\(\);.*?;let oe=async\(\)=>\{/,
    )?.[0];
    if (existingLinuxLaunchActionBlock?.includes("codexLinuxHandleLaunchActionArgs")) {
      patchedSource = patchedSource.replace(existingLinuxLaunchActionBlock, launchActionPatch);
    } else if (
      patchedSource.includes("Launching app") &&
      patchedSource.includes("deepLinks")
    ) {
      throw new Error("Required Linux launch action patch failed: could not add --new-chat/--quick-chat/--prompt-chat handlers");
    } else {
      console.warn("WARN: Could not find Linux launch action handler - skipping --new-chat/--quick-chat/--prompt-chat patch");
    }
  }

  if (patchedSource.includes("Launching app") && !patchedSource.includes("codexLinuxGetSetting=e=>")) {
    throw new Error("Required Linux launch action patch failed: launch flags were not settings-gated");
  }

  return patchedSource;
}

function applyLinuxHotkeyWindowPrewarmPatch(currentSource) {
  let patchedSource = currentSource;

  if (!patchedSource.includes("codexLinuxPrewarmHotkeyWindow=()=>")) {
    return patchedSource;
  }

  const startupPrewarmPatch =
    "process.platform===`linux`&&codexLinuxPrewarmHotkeyWindow(),A=Date.now(),await R.deepLinks.flushPendingDeepLinks()";

  if (patchedSource.includes(startupPrewarmPatch)) {
    return patchedSource;
  }

  const startupPrewarmNeedle =
    "w(`local window ensured`,A,{hostId:z,localWindowVisible:me?.isVisible()??!1}),A=Date.now(),await R.deepLinks.flushPendingDeepLinks()";

  if (patchedSource.includes(startupPrewarmNeedle)) {
    patchedSource = patchedSource.replace(startupPrewarmNeedle, `w(\`local window ensured\`,A,{hostId:z,localWindowVisible:me?.isVisible()??!1}),${startupPrewarmPatch}`);
  } else if (
    patchedSource.includes("process.platform===`linux`&&codexLinuxPrewarmHotkeyWindow(),A=Date.now(),await R.deepLinks.flushPendingDeepLinks()")
  ) {
    // Already patched by an older run.
  } else {
    console.warn("WARN: Could not find Linux hotkey window prewarm insertion point — skipping startup prewarm patch");
  }

  return patchedSource;
}


function patchMainBundleSource(source, iconAsset) {
  let patched = source;
  const iconPathExpression =
    iconAsset == null ? null : `process.resourcesPath+\`/../content/webview/assets/${iconAsset}\``;
  patched = applyLinuxWindowOptionsPatch(patched, iconAsset);
  patched = applyLinuxMenuPatch(patched);
  patched = applyLinuxSetIconPatch(patched, iconAsset);
  patched = applyLinuxOpaqueBackgroundPatch(patched);
  patched = applyLinuxFileManagerPatch(patched);
  patched = applyLinuxTrayPatch(patched, iconPathExpression);
  patched = applyLinuxSingleInstancePatch(patched);
  patched = applyLinuxTrayCloseSettingPatch(patched);
  patched = applyLinuxSettingsPersistencePatch(patched);
  patched = applyLinuxLaunchActionArgsPatch(patched);
  patched = applyLinuxHotkeyWindowPrewarmPatch(patched);
  return patched;
}

function patchPackageJson(extractedDir) {
  const packageJsonPath = path.join(extractedDir, "package.json");
  if (!fs.existsSync(packageJsonPath)) {
    return null;
  }

  const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));
  if (packageJson.desktopName !== "codex-desktop.desktop") {
    packageJson.desktopName = "codex-desktop.desktop";
    fs.writeFileSync(packageJsonPath, `${JSON.stringify(packageJson, null, 2)}\n`, "utf8");
  }
  return packageJson.desktopName;
}

function patchCommentPreloadBundle(extractedDir) {
  const commentPreloadBundle = path.join(extractedDir, ".vite", "build", "comment-preload.js");
  if (!fs.existsSync(commentPreloadBundle)) {
    console.warn(
      `WARN: Could not find comment preload bundle in ${path.dirname(commentPreloadBundle)} — skipping annotation screenshot patch`,
    );
    return;
  }

  const source = fs.readFileSync(commentPreloadBundle, "utf8");
  const patchedSource = applyBrowserAnnotationScreenshotPatch(source);
  if (patchedSource !== source) {
    fs.writeFileSync(commentPreloadBundle, patchedSource, "utf8");
  }
}

function patchExtractedApp(extractedDir) {
  const main = findMainBundle(extractedDir);
  if (main == null) {
    console.warn(
      `WARN: Could not find main bundle in ${path.join(extractedDir, ".vite", "build")} — skipping main-process UI patches`,
    );
  }

  const iconAsset = findIconAsset(extractedDir);
  if (iconAsset == null) {
    console.warn(
      `WARN: Could not find app icon asset in ${path.join(extractedDir, "webview", "assets")} — skipping icon patches`,
    );
  }

  if (main != null) {
    const target = path.join(main.buildDir, main.mainBundle);
    const source = fs.readFileSync(target, "utf8");
    const patchedSource = patchMainBundleSource(source, iconAsset);
    if (patchedSource !== source) {
      fs.writeFileSync(target, patchedSource, "utf8");
    }
  }

  patchCommentPreloadBundle(extractedDir);

  patchAssetFiles(
    extractedDir,
    /^code-theme-.*\.js$/,
    applyLinuxOpaqueWindowsDefaultPatch,
    `WARN: Could not find code theme bundle in ${path.join(
      extractedDir,
      "webview",
      "assets",
    )} — skipping translucent sidebar default patch`,
  );
  patchAssetFiles(
    extractedDir,
    /^general-settings-.*\.js$/,
    applyLinuxOpaqueWindowsDefaultPatch,
    `WARN: Could not find general settings bundle in ${path.join(
      extractedDir,
      "webview",
      "assets",
    )} — skipping translucent sidebar default patch`,
  );
  patchAssetFiles(
    extractedDir,
    /^index-.*\.js$/,
    applyLinuxOpaqueWindowsDefaultPatch,
    `WARN: Could not find webview index bundle in ${path.join(
      extractedDir,
      "webview",
      "assets",
    )} — skipping translucent sidebar default patch`,
  );
  patchAssetFiles(
    extractedDir,
    /^use-resolved-theme-variant-.*\.js$/,
    applyLinuxOpaqueWindowsDefaultPatch,
    `WARN: Could not find resolved theme bundle in ${path.join(
      extractedDir,
      "webview",
      "assets",
    )} — skipping translucent sidebar default patch`,
  );
  patchKeybindsSettingsAssets(extractedDir);

  const desktopName = patchPackageJson(extractedDir);
  console.log("Patched Linux window, shell, and appearance behavior:", {
    target: main == null ? null : path.join(main.buildDir, main.mainBundle),
    mainBundle: main?.mainBundle ?? null,
    iconAsset,
    desktopName,
  });
}

function main() {
  const extractedDir = process.argv[2];

  if (!extractedDir) {
    console.error("Usage: patch-linux-window-ui.js <extracted-app-asar-dir>");
    process.exit(1);
  }

  patchExtractedApp(extractedDir);
}

if (require.main === module) {
  main();
}

module.exports = {
  applyBrowserAnnotationScreenshotPatch,
  applyKeybindsSettingsIndexPatch,
  applyKeybindsSettingsSectionsPatch,
  applyKeybindsSettingsSharedPatch,
  applyLinuxFileManagerPatch,
  applyLinuxHotkeyWindowPrewarmPatch,
  applyLinuxLaunchActionArgsPatch,
  applyLinuxMenuPatch,
  applyLinuxOpaqueBackgroundPatch,
  applyLinuxOpaqueWindowsDefaultPatch,
  applyLinuxSetIconPatch,
  applyLinuxSingleInstancePatch,
  applyLinuxSettingsPersistencePatch,
  applyLinuxTrayCloseSettingPatch,
  applyLinuxTrayPatch,
  applyLinuxWindowOptionsPatch,
  patchCommentPreloadBundle,
  patchKeybindsSettingsAssets,
  patchExtractedApp,
  patchMainBundleSource,
  resolveKeybindsSettingsAsset,
};
