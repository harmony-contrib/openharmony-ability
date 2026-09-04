import { hilog } from "@kit.PerformanceAnalysisKit";
import {
  AsyncPluginBase,
  BridgeAcknowledgement,
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  DOMAIN,
  expectBridgeRequestType,
  getMenuDataCallback,
  getPredefinedActionExecutor,
  WindowManager,
  type PredefinedType,
} from "@ohos-rs/ability";

const SET_MENUBAR_REQUEST_TYPE = "ohos.menu.SetMenubarRequest";
const POPUP_REQUEST_TYPE = "ohos.menu.PopupRequest";
const SET_VISIBLE_REQUEST_TYPE = "ohos.menu.SetVisibleRequest";
const PREDEFINED_REQUEST_TYPE = "ohos.menu.PredefinedRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.menu.Acknowledgement";

interface SetMenubarRequest {
  jsonData: string;
  windowId: string;
}

interface PopupRequest {
  jsonData: string;
  x?: number;
  y?: number;
  windowId: string;
}

interface SetVisibleRequest {
  visible: boolean;
  windowId: string;
}

interface PredefinedRequest {
  action: string;
  windowId?: string;
}

/**
 * Menu bridge plugin for ArkTS.
 *
 * Routes menu bar and popup operations from the Rust `MenuClient` facade to
 * the existing MenuBarComponent callback registry and PredefinedActionExecutor
 * singleton. Replaces the legacy `onMenuRequest` callback path in
 * NativeAbility.setupMenuPopup.
 *
 * Plugin ID: `ohos.menu`
 * Required contexts: ui-context (for popup positioning within the window)
 */
export class MenuPlugin extends AsyncPluginBase {
  readonly id = "ohos.menu";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Menu bridge session is no longer active");
    }

    if (action === "set-menubar") {
      const request = expectBridgeRequestType(payload, "ohos.menu", action, SET_MENUBAR_REQUEST_TYPE) as SetMenubarRequest;
      if (typeof request.jsonData !== "string") {
        throw new Error("set-menubar.jsonData must be a string");
      }
      if (typeof request.windowId !== "string") {
        throw new Error("set-menubar.windowId must be a string");
      }
      const cb = getMenuDataCallback(request.windowId);
      if (!cb) {
        // No MenuBarComponent mounted for this window (e.g. a FloatPage
        // sub-window) or the menubar has not attached yet. Rejecting lets the
        // Rust MenuClient surface the failure instead of caching
        // MENU_HAS_CONTENT as success.
        throw new Error(`set-menubar: no menu callback registered for window '${request.windowId}'`);
      }
      cb.onMenubarJson?.(request.jsonData);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "popup") {
      const request = expectBridgeRequestType(payload, "ohos.menu", action, POPUP_REQUEST_TYPE) as PopupRequest;
      hilog.info(DOMAIN, "MenuPlugin", "popup windowId=%{public}s x=%{public}d y=%{public}d jsonLen=%{public}d",
        request.windowId, request.x ?? 0, request.y ?? 0, request.jsonData.length);
      if (typeof request.jsonData !== "string") {
        throw new Error("popup.jsonData must be a string");
      }
      if (typeof request.windowId !== "string") {
        throw new Error("popup.windowId must be a string");
      }
      const x = request.x ?? 0;
      const y = request.y ?? 0;
      const cb = getMenuDataCallback(request.windowId);
      if (!cb) {
        throw new Error(`popup: no menu callback registered for window '${request.windowId}'`);
      }
      cb.onMenuPopup?.(request.jsonData, x, y);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "set-menubar-visible") {
      const request = expectBridgeRequestType(payload, "ohos.menu", action, SET_VISIBLE_REQUEST_TYPE) as SetVisibleRequest;
      if (typeof request.visible !== "boolean") {
        throw new Error("set-menubar-visible.visible must be a boolean");
      }
      if (typeof request.windowId !== "string") {
        throw new Error("set-menubar-visible.windowId must be a string");
      }
      const cb = getMenuDataCallback(request.windowId);
      if (!cb) {
        throw new Error(`set-menubar-visible: no menu callback registered for window '${request.windowId}'`);
      }
      cb.onMenubarVisible?.(request.visible);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "execute-predefined") {
      const request = expectBridgeRequestType(payload, "ohos.menu", action, PREDEFINED_REQUEST_TYPE) as PredefinedRequest;
      if (typeof request.action !== "string" || !request.action) {
        throw new Error("execute-predefined.action must be a non-empty string");
      }
      const executor = getPredefinedActionExecutor();
      if (!executor) {
        hilog.warn(DOMAIN, "MenuPlugin", "execute-predefined: PredefinedActionExecutor not initialized, action: %{public}s", request.action);
        throw new Error("PredefinedActionExecutor not initialized");
      }
      const actionType = request.action as PredefinedType;
      // Window operations (minimize/hide/close) are deferred via WindowManager to
      // avoid racing with system foreground transitions, matching the legacy
      // ArkHelper.executePredefinedAction behavior.
      const WINDOW_OPERATIONS: PredefinedType[] = ["minimize", "hide", "close"];
      if (WINDOW_OPERATIONS.includes(actionType)) {
        hilog.info(DOMAIN, "MenuPlugin", "Deferring window operation '%{public}s'", request.action);
        const wm = WindowManager.getInstance();
        wm.setPendingAction(() => {
          executor.execute(actionType);
        });
      } else {
        executor.execute(actionType);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    throw new Error(`Unsupported ohos.menu action '${action}'`);
  }
}
