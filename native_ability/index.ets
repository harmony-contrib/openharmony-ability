export { NativeAbility } from "./src/main/ets/ability/NativeAbility";
export {
  AsyncPluginBase,
  LazyPlugin,
  BridgeAbilityCreateLifecyclePayload,
  BridgeEmptyLifecyclePayload,
  BridgeMemoryLevelLifecyclePayload,
  BridgeWindowStageEventLifecyclePayload,
  PluginBase,
  SyncPluginBase,
} from "./src/main/ets/ability/type";
export type {
  AsyncBridgePlugin,
  BridgeBindings,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeLifecycleEvent,
  BridgeLifecycleKind,
  BridgeLifecyclePayload,
  BridgeTypedValue,
  BridgePlugin,
  BridgePluginContext,
  BridgePluginDeclaration,
  BridgePluginExecution,
  BridgePluginFactory,
  BridgePluginHookContext,
  MainThreadSyncBridgePlugin,
  Module,
} from "./src/main/ets/ability/type";
export { DefaultXComponent } from "./src/main/ets/components/DefaultXComponent";
export { notifyPrimaryWebviewController } from "./src/main/ets/components/DefaultXComponent";
export { invokeNativeBackPressInterceptor } from "./src/main/ets/runtime/BackPress";
export { WindowManager } from "./src/main/ets/window/WindowManager";

// ─── Menu helpers (exported for MenuPlugin.ets bridge plugin) ───────────────
export {
  setMenuClickHandler,
  getMenuClickHandler,
  unregisterMenuClickHandler,
  setMenuBarRecoverFn,
  getMenuBarRecoverFn,
  unregisterMenuBarRecoverFn,
  getMenuDataCallback,
  registerMenuDataCallback,
  unregisterMenuDataCallback,
  windowKeyForId,
  isMenubarVisible,
} from "./src/main/ets/components/MenuBarComponent";
export type { MenuDataCallback } from "./src/main/ets/components/MenuBarComponent";
export {
  setPredefinedActionExecutor,
  getPredefinedActionExecutor,
  PredefinedActionExecutor,
  MenuManager,
} from "./src/main/ets/helper/menu";
export type {
  MenuItemData,
  AboutMetadataData,
  PredefinedType,
} from "./src/main/ets/helper/menu_types";

// ─── StatusBar helpers (exported for StatusbarPlugin.ets bridge plugin) ─────
export {
  getAbilityContext,
  createPixelMapFromRgba,
  createPixelMapFromRgbaWH,
  fillMenuItemAbilityName,
  processMenuItemIcons,
  reRegisterStatusBarClickHandlers,
  setCurrentAbilityName,
  setAbilityContext,
} from "./src/main/ets/helper/StatusBarUtils";
export type { StatusBarIconRgba } from "./src/main/ets/ability/type";

// ─── Key synthesis helpers (exported for WebviewPlugin.ets bridge plugin) ────
// ohos-webview-key-synthesis: synthetic DOM KeyboardEvents for the webview
// (ArkWeb's native key events are degenerate — see helper for details).
export {
  notifyKeySynthesisController,
  synthesizeDomKeyEvent,
  KEY_SYNTHESIS_SHIM,
} from "./src/main/ets/helper/key_synthesis";

// ─── Shared bridge-plugin utilities (issue #87 minor-6) ──────────────────────
// DOMAIN used to be re-declared in every plugin that logs via hilog; the
// request-type validator and the { accepted: boolean } acknowledgement shape
// were duplicated per plugin with drifting signatures. Plugins import these
// from "@ohos-rs/ability" instead (pack-plugins.ps1 rewrites that specifier
// to the internal path when assembling the published HAR).
export { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from "./src/main/ets/helper/constants";
export { expectBridgeRequestType, BridgeAcknowledgement } from "./src/main/ets/helper/bridge_plugin_utils";
