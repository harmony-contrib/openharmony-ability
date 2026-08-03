import window from "@ohos.window";
import {
  BridgeCallContext,
  BridgePluginContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  SyncPluginBase,
} from "@ohos-rs/ability";

const AVOID_AREA_REQUEST_TYPE = "ohos.window.AvoidAreaRequest";
const AVOID_AREA_RESPONSE_TYPE = "ohos.window.AvoidAreaResponse";
const CREATE_REQUEST_TYPE = "ohos.window.CreateRequest";
const CREATE_RESPONSE_TYPE = "ohos.window.CreateResponse";
const WINDOW_ID_REQUEST_TYPE = "ohos.window.WindowIdRequest";
const DECORATIONS_REQUEST_TYPE = "ohos.window.DecorationsRequest";
const COLOR_REQUEST_TYPE = "ohos.window.ColorRequest";
const BLUR_REQUEST_TYPE = "ohos.window.BlurRequest";
const MOVE_REQUEST_TYPE = "ohos.window.MoveRequest";
const RESIZE_REQUEST_TYPE = "ohos.window.ResizeRequest";
const FOCUSABLE_REQUEST_TYPE = "ohos.window.FocusableRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.window.Acknowledgement";
const STATE_RESPONSE_TYPE = "ohos.window.StateResponse";

interface AvoidAreaRequest {
  areaType: number;
}

interface WindowCreateRequest {
  name: string;
  width: number;
  height: number;
  x: number;
  y: number;
  decorations: boolean;
  transparent: boolean;
  backgroundColor?: number | null;
}

interface WindowIdRequest {
  windowId: number;
}

interface WindowDecorationsRequest {
  windowId: number;
  decorations: boolean;
}

interface WindowColorRequest {
  windowId: number;
  color: number;
}

interface WindowBlurRequest {
  windowId: number;
  radius: number;
}

interface WindowMoveRequest {
  windowId: number;
  x: number;
  y: number;
}

interface WindowResizeRequest {
  windowId: number;
  width: number;
  height: number;
}

interface WindowFocusableRequest {
  windowId: number;
  focusable: boolean;
}

class AvoidAreaRectResponse {
  readonly top: number;
  readonly left: number;
  readonly width: number;
  readonly height: number;

  constructor(rect: window.Rect) {
    this.top = rect.top;
    this.left = rect.left;
    this.width = rect.width;
    this.height = rect.height;
  }
}

class AvoidAreaValueResponse {
  readonly visible: boolean;
  readonly leftRect: AvoidAreaRectResponse;
  readonly topRect: AvoidAreaRectResponse;
  readonly rightRect: AvoidAreaRectResponse;
  readonly bottomRect: AvoidAreaRectResponse;

  constructor(area: window.AvoidArea) {
    this.visible = area.visible;
    this.leftRect = new AvoidAreaRectResponse(area.leftRect);
    this.topRect = new AvoidAreaRectResponse(area.topRect);
    this.rightRect = new AvoidAreaRectResponse(area.rightRect);
    this.bottomRect = new AvoidAreaRectResponse(area.bottomRect);
  }
}

class AvoidAreaResponse {
  readonly area: AvoidAreaValueResponse;

  constructor(area: window.AvoidArea) {
    this.area = new AvoidAreaValueResponse(area);
  }
}

class WindowCreateResponse {
  readonly windowId: number;

  constructor(windowId: number) {
    this.windowId = windowId;
  }
}

class WindowAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class WindowStateResponse {
  readonly value: boolean;

  constructor(value: boolean) {
    this.value = value;
  }
}

function parseAvoidAreaRequest(payload: BridgeTypedValue): AvoidAreaRequest {
  if (payload.typeName !== AVOID_AREA_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.get-avoid-area requires bridge type ${AVOID_AREA_REQUEST_TYPE}`);
  }
  const request = payload.value as AvoidAreaRequest;
  if (!Number.isInteger(request?.areaType)) {
    throw new Error("get-avoid-area.areaType must be an integer");
  }
  return request;
}

function parseCreateRequest(payload: BridgeTypedValue): WindowCreateRequest {
  if (payload.typeName !== CREATE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.create-os-window requires bridge type ${CREATE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowCreateRequest;
  if (!request.name?.trim()) {
    throw new Error("create-os-window.name must not be empty");
  }
  if (request.width <= 0 || request.height <= 0) {
    throw new Error("create-os-window.width and height must be positive");
  }
  return request;
}

function parseWindowIdRequest(payload: BridgeTypedValue): WindowIdRequest {
  if (payload.typeName !== WINDOW_ID_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window requires bridge type ${WINDOW_ID_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowIdRequest;
  if (!Number.isInteger(request?.windowId)) {
    throw new Error("windowId must be an integer");
  }
  return request;
}

function parseDecorationsRequest(payload: BridgeTypedValue): WindowDecorationsRequest {
  if (payload.typeName !== DECORATIONS_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-decorations requires bridge type ${DECORATIONS_REQUEST_TYPE}`);
  }
  return payload.value as WindowDecorationsRequest;
}

function parseColorRequest(payload: BridgeTypedValue): WindowColorRequest {
  if (payload.typeName !== COLOR_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-background-color requires bridge type ${COLOR_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowColorRequest;
  if (!Number.isInteger(request?.color)) {
    throw new Error("color must be an integer in 0xAARRGGBB format");
  }
  return request;
}

function parseBlurRequest(payload: BridgeTypedValue): WindowBlurRequest {
  if (payload.typeName !== BLUR_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-blur requires bridge type ${BLUR_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowBlurRequest;
  if (
    typeof request.radius !== "number" ||
    !Number.isFinite(request.radius) ||
    request.radius < 0
  ) {
    throw new Error("set-blur.radius must be a non-negative finite number");
  }
  return request;
}

function parseMoveRequest(payload: BridgeTypedValue): WindowMoveRequest {
  if (payload.typeName !== MOVE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.move-to requires bridge type ${MOVE_REQUEST_TYPE}`);
  }
  return payload.value as WindowMoveRequest;
}

function parseResizeRequest(payload: BridgeTypedValue): WindowResizeRequest {
  if (payload.typeName !== RESIZE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.resize requires bridge type ${RESIZE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowResizeRequest;
  if (request.width <= 0 || request.height <= 0) {
    throw new Error("resize.width and height must be positive");
  }
  return request;
}

function parseFocusableRequest(payload: BridgeTypedValue): WindowFocusableRequest {
  if (payload.typeName !== FOCUSABLE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-focusable requires bridge type ${FOCUSABLE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowFocusableRequest;
  if (typeof request.focusable !== "boolean") {
    throw new Error("set-focusable.focusable must be a boolean");
  }
  return request;
}

/** Per-session registry of OS sub-windows created through this plugin. */
class SubWindowRegistry {
  private static readonly windows: Map<string, window.Window> = new Map();

  static put(sessionId: string, windowId: number, win: window.Window): void {
    SubWindowRegistry.windows.set(`${sessionId}:${windowId}`, win);
  }

  static get(sessionId: string, windowId: number): window.Window {
    const win = SubWindowRegistry.windows.get(`${sessionId}:${windowId}`);
    if (!win) {
      throw new Error(`Unknown OS sub-window '${windowId}' for session '${sessionId}'`);
    }
    return win;
  }

  static remove(sessionId: string, windowId: number): void {
    SubWindowRegistry.windows.delete(`${sessionId}:${windowId}`);
  }
}

export class WindowPlugin extends SyncPluginBase {
  readonly id = "ohos.window";
  readonly version = 1;
  readonly requires: BridgeContextRequirement[] = ["window-stage"];
  private pluginContext?: BridgePluginContext;

  override attachContext(context: BridgePluginContext): void {
    super.attachContext(context);
    this.pluginContext = context;
  }

  private requireContext(): BridgePluginContext {
    const context = this.pluginContext;
    if (context === undefined) {
      throw new Error(`Bridge plugin '${this.id}' was used before its context was attached`);
    }
    return context;
  }

  private dynamic(win: window.Window): ESObject {
    return win as ESObject;
  }

  invokeSync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): BridgeTypedValue {
    if (action === "get-avoid-area") {
      const request = parseAvoidAreaRequest(payload);
      try {
        const mainWindow = context.getWindowStage().getMainWindowSync();
        const areaType = request.areaType as window.AvoidAreaType;
        const response = new AvoidAreaResponse(mainWindow.getWindowAvoidArea(areaType));
        return { typeName: AVOID_AREA_RESPONSE_TYPE, value: response };
      } catch (error) {
        throw new Error(`Unable to get window avoid area: ${String(error)}`);
      }
    }

    if (action === "create-os-window") {
      const request = parseCreateRequest(payload);
      const windowStage = context.getWindowStage();
      const windowId = WindowPlugin.nextWindowId();
      try {
        // createSubWindow is async; the sync action hands out the window id immediately and
        // registers the window when creation resolves. Decorations/content are applied by
        // the business page through the returned id.
        const sessionId = this.requireContext().sessionId;
        windowStage
          .createSubWindow(request.name)
          .then((win: window.Window) => {
            SubWindowRegistry.put(sessionId, windowId, win);
          })
          .catch((error: Error) => {
            console.error(`[WindowPlugin] createSubWindow failed: ${String(error)}`);
          });
        return { typeName: CREATE_RESPONSE_TYPE, value: new WindowCreateResponse(windowId) };
      } catch (error) {
        throw new Error(`createSubWindow failed: ${String(error)}`);
      }
    }

    if (action === "set-decorations") {
      const request = parseDecorationsRequest(payload);
      const win = SubWindowRegistry.get(this.requireContext().sessionId, request.windowId);
      try {
        // Decorations are rendered by the business page; the registry entry keeps the
        // window alive across calls. No-op beyond validation on this platform.
        void win;
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`set-decorations failed: ${String(error)}`);
      }
    }

    if (action === "set-background-color") {
      const request = parseColorRequest(payload);
      const win = SubWindowRegistry.get(this.requireContext().sessionId, request.windowId);
      try {
        this.dynamic(win).setWindowBackgroundColor(`#${request.color.toString(16).padStart(8, "0")}`);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`setWindowBackgroundColor failed: ${String(error)}`);
      }
    }

    if (action === "set-blur") {
      const request = parseBlurRequest(payload);
      const win = SubWindowRegistry.get(this.requireContext().sessionId, request.windowId);
      try {
        this.dynamic(win).setBlur(request.radius);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`setBlur failed: ${String(error)}`);
      }
    }

    if (action === "focus") {
      const request = parseWindowIdRequest(payload);
      const win = SubWindowRegistry.get(this.requireContext().sessionId, request.windowId);
      try {
        this.dynamic(win).focus();
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`focus failed: ${String(error)}`);
      }
    }

    if (action === "set-focusable") {
      const request = parseFocusableRequest(payload);
      const win = SubWindowRegistry.get(this.requireContext().sessionId, request.windowId);
      try {
        this.dynamic(win).setFocusable(request.focusable);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`setFocusable failed: ${String(error)}`);
      }
    }

    if (action === "move-to") {
      const request = parseMoveRequest(payload);
      const win = SubWindowRegistry.get(this.requireContext().sessionId, request.windowId);
      try {
        this.dynamic(win).moveWindowTo(request.x, request.y);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`moveWindowTo failed: ${String(error)}`);
      }
    }

    if (action === "resize") {
      const request = parseResizeRequest(payload);
      const win = SubWindowRegistry.get(this.requireContext().sessionId, request.windowId);
      try {
        this.dynamic(win).resize(request.width, request.height);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
      } catch (error) {
        throw new Error(`resize failed: ${String(error)}`);
      }
    }

    if (action === "minimize") {
      return this.windowCommand(context, "minimize", payload);
    }
    if (action === "maximize") {
      return this.windowCommand(context, "maximize", payload);
    }
    if (action === "restore") {
      return this.windowCommand(context, "restore", payload);
    }
    if (action === "recover") {
      return this.windowCommand(context, "recover", payload);
    }
    if (action === "show") {
      return this.windowCommand(context, "show", payload);
    }
    if (action === "is-maximized") {
      return this.windowState(context, "is-maximized", payload);
    }
    if (action === "is-minimized") {
      return this.windowState(context, "is-minimized", payload);
    }

    throw new Error(`Unsupported ohos.window action '${action}'`);
  }

  private windowCommand(
    context: BridgeCallContext,
    action: string,
    payload: BridgeTypedValue,
  ): BridgeTypedValue {
    const request = parseWindowIdRequest(payload);
    const win = SubWindowRegistry.get(this.requireContext().sessionId, request.windowId);
    try {
      if (action === "minimize") {
        this.dynamic(win).minimize();
      } else if (action === "maximize") {
        this.dynamic(win).maximize();
      } else if (action === "restore") {
        this.dynamic(win).restore();
      } else if (action === "recover" || action === "show") {
        this.dynamic(win).showWindow();
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WindowAcknowledgement(true) };
    } catch (error) {
      throw new Error(`${action} failed: ${String(error)}`);
    }
  }

  private windowState(
    context: BridgeCallContext,
    action: string,
    payload: BridgeTypedValue,
  ): BridgeTypedValue {
    const request = parseWindowIdRequest(payload);
    const win = SubWindowRegistry.get(this.requireContext().sessionId, request.windowId);
    try {
      const dynamic: ESObject = this.dynamic(win);
      const value: boolean =
        action === "is-maximized" ? (dynamic.isMaximized() as boolean) : (dynamic.isMinimized() as boolean);
      return { typeName: STATE_RESPONSE_TYPE, value: new WindowStateResponse(value) };
    } catch (error) {
      throw new Error(`${action} failed: ${String(error)}`);
    }
  }

  private static nextWindowId(): number {
    return Date.now() % 0x7fffffff;
  }
}
