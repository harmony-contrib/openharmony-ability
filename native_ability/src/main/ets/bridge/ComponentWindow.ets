import window from "@ohos.window";
import { UIContext } from "@ohos.arkui.UIContext";

/** Resolve the window that owns this component, including components in subwindows. */
export function resolveComponentWindow(ui: UIContext, moduleName: string): window.Window {
  const name = ui.getWindowName();
  if (!name) {
    throw new Error(`Native module '${moduleName}' has no component Window`);
  }
  try {
    return window.findWindow(name);
  } catch (error) {
    throw new Error(
      `Unable to resolve Window '${name}' for native module '${moduleName}': ${String(error)}`,
    );
  }
}

/** Native IME accepts a real positive platform Window ID, independent of routing IDs. */
export function componentPlatformWindowId(ui: UIContext, moduleName: string): number {
  const id = resolveComponentWindow(ui, moduleName).getWindowProperties().id;
  if (!Number.isInteger(id) || id <= 0 || id > 0x7fffffff) {
    throw new Error(`Native module '${moduleName}' has an invalid platform Window ID`);
  }
  return id;
}
