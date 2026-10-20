import type { BridgeCallContext } from "@ohos-rs/ability";
import type { MenuItemData } from "./menu_types";
import { hilog } from "@kit.PerformanceAnalysisKit";

// --- Per-window click handler registry (MW-1) ---
const windowMenuClickHandlers: Map<string, (item: MenuItemData) => void> = new Map();
const menuWillOpenHandlers: Map<string, (windowId: number) => void> = new Map();

export function setMenuWillOpenHandler(
  handler: ((windowId: number) => void) | null,
  key: string = "main",
): void {
  if (handler) menuWillOpenHandlers.set(key, handler);
  else menuWillOpenHandlers.delete(key);
}

export function notifyMenuWillOpen(windowId: number, key: string): void {
  menuWillOpenHandlers.get(key)?.(windowId);
}

export function setMenuClickHandler(
  windowId: number | string,
  handler: (item: MenuItemData) => void,
): void {
  hilog.info(0x1999, "MenuBar", "setMenuClickHandler registered for windowId=%{public}d", windowId);
  windowMenuClickHandlers.set(windowKeyForId(windowId), handler);
}

export function getMenuClickHandler(
  windowId: number | string,
): ((item: MenuItemData) => void) | null {
  const handler = windowMenuClickHandlers.get(windowKeyForId(windowId)) ?? null;
  if (!handler) {
    hilog.warn(
      0x1999,
      "MenuBar",
      "getMenuClickHandler NULL for windowId=%{public}d (map size=%{public}d)",
      windowId,
      windowMenuClickHandlers.size,
    );
  }
  return handler;
}

export function unregisterMenuClickHandler(windowId: number | string): void {
  windowMenuClickHandlers.delete(windowKeyForId(windowId));
}

// --- Per-window recover function registry (MW-1) ---
const windowRecoverFns: Map<string, () => void> = new Map();

export function setMenuBarRecoverFn(windowId: number | string, fn: () => void): void {
  windowRecoverFns.set(windowKeyForId(windowId), fn);
}

export function getMenuBarRecoverFn(windowId: number | string): (() => void) | null {
  return windowRecoverFns.get(windowKeyForId(windowId)) ?? null;
}

export function unregisterMenuBarRecoverFn(windowId: number | string): void {
  windowRecoverFns.delete(windowKeyForId(windowId));
}

// --- Per-window menu data callback registry (MW-5) ---
export interface MenuDataCallback {
  onMenubarJson?: (json: string) => void;
  onMenubarVisible?: (visible: boolean) => void;
  onMenuPopup?: (json: string, x: number, y: number) => void;
  onMenuCommands?: (items: MenuItemData[], x: number, y: number, restoreFocusId?: string) => void;
  onMenuShown?: (shown: boolean) => void;
  onApplicationMenu?: (
    menuName: string | undefined,
    x: number,
    y: number,
    restoreFocusId?: string,
  ) => void;
}

const menuDataCallbacks: Map<string, MenuDataCallback> = new Map();

export function registerMenuDataCallback(windowKey: string, callback: MenuDataCallback): void {
  menuDataCallbacks.set(windowKey, callback);
  const listeners = menuDataWaiters.get(windowKey);
  menuDataWaiters.delete(windowKey);
  listeners?.forEach((listener): void => listener(callback));
}

export function getMenuDataCallback(windowKey: string): MenuDataCallback | undefined {
  return menuDataCallbacks.get(windowKey);
}

export function unregisterMenuDataCallback(
  windowKey: string,
  callback?: MenuDataCallback,
): boolean {
  if (callback && menuDataCallbacks.get(windowKey) !== callback) return false;
  return menuDataCallbacks.delete(windowKey);
}

const menuDataWaiters: Map<string, Set<(callback?: MenuDataCallback) => void>> = new Map();

export function cancelMenuDataWaiters(key: string): void {
  const listeners = menuDataWaiters.get(key);
  menuDataWaiters.delete(key);
  listeners?.forEach((listener): void => listener());
}

export function waitForMenuDataCallback(
  key: string,
  context: BridgeCallContext,
): Promise<MenuDataCallback> {
  const callback = menuDataCallbacks.get(key);
  if (callback) return Promise.resolve(callback);
  return new Promise<MenuDataCallback>((resolve, reject): void => {
    let removeCancel: () => void = (): void => {};
    const ready = (value?: MenuDataCallback): void => {
      removeCancel();
      if (value) resolve(value);
      else reject(new Error("Menu attachment was cancelled"));
    };
    let listeners = menuDataWaiters.get(key);
    if (!listeners) {
      listeners = new Set();
      menuDataWaiters.set(key, listeners);
    }
    listeners.add(ready);
    removeCancel = context.onCancel((): void => {
      listeners?.delete(ready);
      if (listeners?.size === 0 && menuDataWaiters.get(key) === listeners)
        menuDataWaiters.delete(key);
      reject(new Error("Menu attachment was cancelled"));
    });
  });
}

/**
 * Converts a numeric windowId to the AppStorage key suffix.
 * windowId 0 → "main", others → string representation.
 */
export function windowKeyForId(windowId: number | string): string {
  return windowId === 0 ? "main" : String(windowId);
}

// --- Per-window menubar visibility tracker (for ESC handler in parent pages) ---
export const menubarVisibilityTracker: Map<string, boolean> = new Map();

export function isMenubarVisible(windowId: number | string): boolean {
  return menubarVisibilityTracker.get(windowKeyForId(windowId)) ?? true;
}
