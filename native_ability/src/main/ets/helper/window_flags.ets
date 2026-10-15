// Per-window webview feature flags. This state is window-builder configuration
// (WebviewWindowBuilder::with_clipboard / with_zoom_hotkeys), not menu behavior,
// so it stays with the core window layer: WindowManager.setWebviewFlags is the
// only setter, and it must not depend on the menu plugin package. The menu
// plugin's key port reads the flags to decide whether clipboard / zoom
// shortcuts are forwarded to ArkWeb native handling.
//
// rs<->ets correspondence: consumed on the Rust side by the window creation
// path in crates/ability (webview flag payload), mirrored here.

// Per-window clipboard flag: windowId -> clipboard enabled (default true = ArkWeb native).
// Set by WindowManager.setWebviewFlags (from WebviewPlugin.create's payload.clipboard); read by
// the menu plugin's key port to decide whether to block clipboard shortcuts.
// See ohos-webview-flag-clipboard spec.
const clipboardEnabledMap: Map<number, boolean> = new Map();

export function setClipboardEnabled(windowId: number, enabled: boolean): void {
  clipboardEnabledMap.set(windowId, enabled);
}

export function isClipboardEnabled(windowId: number): boolean {
  // Default true (ArkWeb native clipboard) when not explicitly set.
  return clipboardEnabledMap.get(windowId) ?? true;
}

export function clearClipboardEnabled(windowId: number): void {
  clipboardEnabledMap.delete(windowId);
}

// Per-window zoom-hotkeys flag: windowId -> enabled (default true = ArkWeb native).
// Set by WindowManager.setWebviewFlags (from WebviewPlugin.create's payload.zoomHotkeys); read
// by the menu plugin's key port to decide whether to block zoom hotkeys.
// See ohos-webview-flag-zoom-hotkeys spec.
const zoomHotkeysEnabledMap: Map<number, boolean> = new Map();

export function setZoomHotkeysEnabled(windowId: number, enabled: boolean): void {
  zoomHotkeysEnabledMap.set(windowId, enabled);
}

export function isZoomHotkeysEnabled(windowId: number): boolean {
  // Default true (ArkWeb native zoom) when not explicitly set.
  return zoomHotkeysEnabledMap.get(windowId) ?? true;
}

export function clearZoomHotkeysEnabled(windowId: number): void {
  zoomHotkeysEnabledMap.delete(windowId);
}
