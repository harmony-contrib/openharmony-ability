import window from "@ohos.window";
import { UIContext } from "@ohos.arkui.UIContext";
import { hilog } from "@kit.PerformanceAnalysisKit";

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

/** Zero selects the platform main-window default; routing IDs are never platform IDs. */
export function componentPlatformWindowId(
  ui: UIContext,
  moduleName: string,
  routingWindowId: number = 0,
): number {
  let id: number;
  try {
    id = resolveComponentWindow(ui, moduleName).getWindowProperties().id;
  } catch (error) {
    if (routingWindowId !== 0) {
      throw new Error(`Cannot resolve sub-window '${routingWindowId}': ${String(error)}`);
    }
    hilog.warn(
      0xa01999,
      "ComponentWindow",
      "Main Window lookup unavailable for '%{public}s'; using platform default: %{public}s",
      moduleName,
      String(error),
    );
    return 0;
  }
  if (!Number.isInteger(id) || id < 0 || id > 0x7fffffff || (routingWindowId !== 0 && id === 0)) {
    throw new Error(`Native module '${moduleName}' has an invalid platform Window ID`);
  }
  return id;
}
