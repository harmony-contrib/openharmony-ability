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
  BridgeDispatchHook,
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
export { setPrimaryWebviewControllerCallback } from "./src/main/ets/components/DefaultXComponent";
export { invokeNativeBackPressInterceptor } from "./src/main/ets/runtime/BackPress";
export { WindowManager } from "./src/main/ets/window/WindowManager";

// ─── Menubar extension seam (consumed by the menu plugin package) ────────────
// The menu UI cluster (MenuBarComponent / MenuPopup / menu.ets / menu_types /
// accelerator matcher) lives in plugins/menu (@ohos-rs/ability-plugin-menu,
// mirroring crates/plugin-menu). Core pages compose the menubar through this
// registered slot and notify the menu plugin through this port — the core
// package never imports the menu package.
export {
  setMenuBarSlotBuilder,
  getMenuBarSlotBuilder,
  setMenuBarPort,
  getMenuBarPort,
} from "./src/main/ets/components/MenuBarSlot";
export type {
  MenuBarSlotProps,
  MenuBarSlotBuilder,
  MenuBarPort,
} from "./src/main/ets/components/MenuBarSlot";

// ─── Per-window webview feature flags (set by WindowManager, read by the
// menu plugin's key port) ────────────────────────────────────────────────────
export {
  setClipboardEnabled,
  isClipboardEnabled,
  clearClipboardEnabled,
  setZoomHotkeysEnabled,
  isZoomHotkeysEnabled,
  clearZoomHotkeysEnabled,
} from "./src/main/ets/helper/window_flags";

// ─── Bridge host registry (consumed by the statusbar plugin package) ─────────
// StatusBarUtils.ets (plugins/statusbar) registers SCB receiver callbacks that
// fire outside any plugin-instance context, so its reverse events go through
// the process-wide registry instead of a BridgePluginContext.
export { BridgeHostRegistry } from "./src/main/ets/bridge/BridgeHost";

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
export { DOMAIN, NATIVE_MODULE_STORAGE_KEY, MAIN_WINDOW_ID } from "./src/main/ets/helper/constants";
export {
  expectBridgeRequestType,
  BridgeAcknowledgement,
} from "./src/main/ets/helper/bridge_plugin_utils";
