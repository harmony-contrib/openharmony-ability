import window from "@ohos.window";
import { setWindowIcon } from "./WindowIcon";
import { parseCustomCursor } from "./CustomCursor";
import { BusinessError, deviceInfo } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
// Static imports are REQUIRED here: dynamic import('@kit.NotificationKit') /
// ('@kit.IMEKit') fail to load their native so on device (libnotificationkit.z.so
// not exist) — same lesson as the print fix (2026-08-20).
import { notificationManager } from "@kit.NotificationKit";
import { inputMethod } from "@kit.IMEKit";
import {
  BridgeAcknowledgement,
  BridgeLifecycleEvent,
  BridgeCallContext,
  BridgeComponentTouchEvent,
  BridgePluginContext,
  BridgePluginHookContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  AsyncPluginBase,
  DOMAIN,
  WindowManager,
} from "@ohos-rs/ability";

import { PromptDialogs, WindowPromptRequest } from "./PromptDialogs";
import { WindowPointer } from "./WindowPointer";

const TAG: string = "WindowPlugin";
const MOVE_REQUESTED_TYPE = "ohos.window.MoveRequested";
const MOVE_RESPONSE_TYPE = "ohos.window.MoveResponse";
const CLOSE_REQUESTED_TYPE = "ohos.window.CloseRequested";
const CLOSE_RESPONSE_TYPE = "ohos.window.CloseResponse";

interface WindowCloseResponse {
  preventClose: boolean;
}

const AVOID_AREA_REQUEST_TYPE = "ohos.window.AvoidAreaRequest";
const AVOID_AREA_RESPONSE_TYPE = "ohos.window.AvoidAreaResponse";
const CREATE_REQUEST_TYPE = "ohos.window.CreateRequest";
const CREATE_RESPONSE_TYPE = "ohos.window.CreateResponse";
const WINDOW_ID_REQUEST_TYPE = "ohos.window.WindowIdRequest";
const DECORATIONS_REQUEST_TYPE = "ohos.window.DecorationsRequest";
const FULLSCREEN_REQUEST_TYPE = "ohos.window.FullscreenRequest";
const COLOR_REQUEST_TYPE = "ohos.window.ColorRequest";
const BLUR_REQUEST_TYPE = "ohos.window.BlurRequest";
const MOVE_REQUEST_TYPE = "ohos.window.MoveRequest";
const RESIZE_REQUEST_TYPE = "ohos.window.ResizeRequest";
const FOCUSABLE_REQUEST_TYPE = "ohos.window.FocusableRequest";
const TOUCHABLE_REQUEST_TYPE = "ohos.window.TouchableRequest";
const TOPMOST_REQUEST_TYPE = "ohos.window.TopmostRequest";
const TITLE_REQUEST_TYPE = "ohos.window.TitleRequest";
const LIMITS_REQUEST_TYPE = "ohos.window.LimitsRequest";
const IME_POSITION_REQUEST_TYPE = "ohos.window.ImePositionRequest";
const DRAGGABLE_REQUEST_TYPE = "ohos.window.DraggableRequest";
const KEEP_SCREEN_ON_REQUEST_TYPE = "ohos.window.KeepScreenOnRequest";
const CURSOR_ICON_REQUEST_TYPE = "ohos.window.CursorIconRequest";
const CURSOR_VISIBLE_REQUEST_TYPE = "ohos.window.CursorVisibleRequest";
const DECORATION_FLAGS_REQUEST_TYPE = "ohos.window.DecorationFlagsRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.window.Acknowledgement";
const STATE_RESPONSE_TYPE = "ohos.window.StateResponse";
const IME_POSITION_RESPONSE_TYPE = "ohos.window.ImePositionResponse";
const REAL_WINDOW_ID_RESPONSE_TYPE = "ohos.window.RealWindowIdResponse";
const MAX_SAFE_INTEGER: number = 9007199254740991;
const MAX_ARGB_COLOR: number = 0xffffffff;

// Monotonic notification id for request-user-attention — avoids concurrent
// calls sharing a fixed id and overwriting each other (upstream PR#45 review F3).
let attentionNotifId: number = 0;

function isSafeInteger(value: number): boolean {
  return Number.isInteger(value) && Math.abs(value) <= MAX_SAFE_INTEGER;
}

function isWindowId(value: number): boolean {
  return isSafeInteger(value) && value >= 0;
}

interface WindowStackRequest {
  displayId: number;
  windowIds: number[];
}

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

interface WindowFullscreenRequest {
  windowId: number;
  on: boolean;
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

interface WindowTouchableRequest {
  windowId: number;
  touchable: boolean;
}

interface WindowTopmostRequest {
  windowId: number;
  topmost: boolean;
}

interface WindowTitleRequest {
  windowId: number;
  title: string;
}

interface WindowLimitsRequest {
  windowId: number;
  minWidth: number;
  minHeight: number;
  maxWidth: number;
  maxHeight: number;
}

interface ImePositionRequest {
  windowId: number;
  x: number;
  y: number;
}

interface WindowDraggableRequest {
  windowId: number;
  enable: boolean;
}

interface WindowKeepScreenOnRequest {
  windowId: number;
  on: boolean;
}

interface CursorIconRequest {
  windowId: number;
  style: number;
}

interface CursorVisibleRequest {
  /** Global pointer visibility — no windowId (pointer.setPointerVisible is process-wide). */
  visible: boolean;
}

interface DecorationFlagsRequest {
  windowId: number;
  flags: number;
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

class WindowStateResponse {
  readonly value: boolean;

  constructor(value: boolean) {
    this.value = value;
  }
}

class ImePositionResponse {
  readonly ok: boolean;
  readonly code: number;
  readonly message: string;

  constructor(ok: boolean, code: number, message: string) {
    this.ok = ok;
    this.code = code;
    this.message = message;
  }
}

class RealWindowIdResponse {
  readonly windowId: number;

  constructor(windowId: number) {
    this.windowId = windowId;
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
  if (
    !isSafeInteger(request.width) ||
    !isSafeInteger(request.height) ||
    request.width <= 0 ||
    request.height <= 0
  ) {
    throw new Error("create-os-window.width and height must be positive");
  }
  if (
    !isSafeInteger(request.x) ||
    !isSafeInteger(request.y) ||
    typeof request.decorations !== "boolean" ||
    typeof request.transparent !== "boolean"
  ) {
    throw new Error("create-os-window position and appearance fields are invalid");
  }
  if (
    request.backgroundColor !== undefined &&
    request.backgroundColor !== null &&
    (!Number.isInteger(request.backgroundColor) ||
      request.backgroundColor < 0 ||
      request.backgroundColor > MAX_ARGB_COLOR)
  ) {
    throw new Error("create-os-window.backgroundColor must be an integer in 0xAARRGGBB format");
  }
  return request;
}

function parseWindowIdRequest(payload: BridgeTypedValue): WindowIdRequest {
  if (payload.typeName !== WINDOW_ID_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window requires bridge type ${WINDOW_ID_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowIdRequest;
  if (!isWindowId(request?.windowId)) {
    throw new Error("windowId must be a non-negative integer");
  }
  return request;
}

function parseDecorationsRequest(payload: BridgeTypedValue): WindowDecorationsRequest {
  if (payload.typeName !== DECORATIONS_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-decorations requires bridge type ${DECORATIONS_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowDecorationsRequest;
  if (!isWindowId(request?.windowId) || typeof request.decorations !== "boolean") {
    throw new Error("set-decorations requires a valid windowId and boolean decorations");
  }
  return request;
}

function parseFullscreenRequest(payload: BridgeTypedValue): WindowFullscreenRequest {
  if (payload.typeName !== FULLSCREEN_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-fullscreen requires bridge type ${FULLSCREEN_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowFullscreenRequest;
  if (!isWindowId(request?.windowId) || typeof request.on !== "boolean") {
    throw new Error("set-fullscreen requires a valid windowId and boolean on");
  }
  return request;
}

function parseColorRequest(payload: BridgeTypedValue): WindowColorRequest {
  if (payload.typeName !== COLOR_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-background-color requires bridge type ${COLOR_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowColorRequest;
  if (
    !isWindowId(request?.windowId) ||
    !Number.isInteger(request.color) ||
    request.color < 0 ||
    request.color > MAX_ARGB_COLOR
  ) {
    throw new Error("set-background-color requires a valid windowId and integer color");
  }
  return request;
}

function parseBlurRequest(payload: BridgeTypedValue): WindowBlurRequest {
  if (payload.typeName !== BLUR_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-blur requires bridge type ${BLUR_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowBlurRequest;
  if (
    !isWindowId(request?.windowId) ||
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
  const request = payload.value as WindowMoveRequest;
  if (!isWindowId(request?.windowId) || !isSafeInteger(request.x) || !isSafeInteger(request.y)) {
    throw new Error("move-to requires a valid windowId and finite coordinates");
  }
  return request;
}

function parseResizeRequest(payload: BridgeTypedValue): WindowResizeRequest {
  if (payload.typeName !== RESIZE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.resize requires bridge type ${RESIZE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowResizeRequest;
  if (
    !isWindowId(request?.windowId) ||
    !isSafeInteger(request.width) ||
    !isSafeInteger(request.height) ||
    request.width <= 0 ||
    request.height <= 0
  ) {
    throw new Error("resize.width and height must be positive");
  }
  return request;
}

function parseFocusableRequest(payload: BridgeTypedValue): WindowFocusableRequest {
  if (payload.typeName !== FOCUSABLE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-focusable requires bridge type ${FOCUSABLE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowFocusableRequest;
  if (!isWindowId(request?.windowId) || typeof request.focusable !== "boolean") {
    throw new Error("set-focusable.focusable must be a boolean");
  }
  return request;
}

function parseTouchableRequest(payload: BridgeTypedValue): WindowTouchableRequest {
  if (payload.typeName !== TOUCHABLE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-touchable requires bridge type ${TOUCHABLE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowTouchableRequest;
  if (!isWindowId(request?.windowId) || typeof request.touchable !== "boolean") {
    throw new Error("set-touchable.touchable must be a boolean");
  }
  return request;
}

function parseTopmostRequest(payload: BridgeTypedValue): WindowTopmostRequest {
  if (payload.typeName !== TOPMOST_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-topmost requires bridge type ${TOPMOST_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowTopmostRequest;
  if (!isWindowId(request?.windowId) || typeof request.topmost !== "boolean") {
    throw new Error("set-topmost requires a valid windowId and boolean topmost");
  }
  return request;
}

function parseTitleRequest(payload: BridgeTypedValue): WindowTitleRequest {
  if (payload.typeName !== TITLE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-title requires bridge type ${TITLE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowTitleRequest;
  if (!isWindowId(request?.windowId) || typeof request.title !== "string") {
    throw new Error("set-title requires a valid windowId and string title");
  }
  return request;
}

function parseLimitsRequest(payload: BridgeTypedValue): WindowLimitsRequest {
  if (payload.typeName !== LIMITS_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-limits requires bridge type ${LIMITS_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowLimitsRequest;
  if (
    !isWindowId(request?.windowId) ||
    !isSafeInteger(request.minWidth) ||
    !isSafeInteger(request.minHeight) ||
    !isSafeInteger(request.maxWidth) ||
    !isSafeInteger(request.maxHeight) ||
    request.minWidth < 0 ||
    request.minHeight < 0 ||
    request.maxWidth < 0 ||
    request.maxHeight < 0
  ) {
    throw new Error("set-limits requires a valid windowId and non-negative integer limits");
  }
  return request;
}

function parseImePositionRequest(payload: BridgeTypedValue): ImePositionRequest {
  if (payload.typeName !== IME_POSITION_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(
      `ohos.window.set-ime-position requires bridge type ${IME_POSITION_REQUEST_TYPE}`,
    );
  }
  const request = payload.value as ImePositionRequest;
  if (!isWindowId(request?.windowId) || !isSafeInteger(request?.x) || !isSafeInteger(request?.y)) {
    throw new Error("set-ime-position requires a valid windowId and integer x/y");
  }
  return request;
}

function parseDraggableRequest(payload: BridgeTypedValue): WindowDraggableRequest {
  if (payload.typeName !== DRAGGABLE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-draggable requires bridge type ${DRAGGABLE_REQUEST_TYPE}`);
  }
  const request = payload.value as WindowDraggableRequest;
  if (!isWindowId(request?.windowId) || typeof request.enable !== "boolean") {
    throw new Error("set-draggable requires a valid windowId and boolean enable");
  }
  return request;
}

function parseKeepScreenOnRequest(payload: BridgeTypedValue): WindowKeepScreenOnRequest {
  if (payload.typeName !== KEEP_SCREEN_ON_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(
      `ohos.window.set-keep-screen-on requires bridge type ${KEEP_SCREEN_ON_REQUEST_TYPE}`,
    );
  }
  const request = payload.value as WindowKeepScreenOnRequest;
  if (!isWindowId(request?.windowId) || typeof request.on !== "boolean") {
    throw new Error("set-keep-screen-on requires a valid windowId and boolean on");
  }
  return request;
}

function parseCursorIconRequest(payload: BridgeTypedValue): CursorIconRequest {
  if (payload.typeName !== CURSOR_ICON_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.window.set-cursor-icon requires bridge type ${CURSOR_ICON_REQUEST_TYPE}`);
  }
  const request = payload.value as CursorIconRequest;
  if (!isWindowId(request?.windowId) || !isSafeInteger(request?.style)) {
    throw new Error("set-cursor-icon requires a valid windowId and integer style");
  }
  return request;
}

function parseCursorVisibleRequest(payload: BridgeTypedValue): CursorVisibleRequest {
  if (payload.typeName !== CURSOR_VISIBLE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(
      `ohos.window.set-cursor-visible requires bridge type ${CURSOR_VISIBLE_REQUEST_TYPE}`,
    );
  }
  const request = payload.value as CursorVisibleRequest;
  if (typeof request?.visible !== "boolean") {
    throw new Error("set-cursor-visible requires a boolean visible");
  }
  return request;
}

function parseDecorationFlagsRequest(payload: BridgeTypedValue): DecorationFlagsRequest {
  if (payload.typeName !== DECORATION_FLAGS_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(
      `ohos.window.set-decoration-flags requires bridge type ${DECORATION_FLAGS_REQUEST_TYPE}`,
    );
  }
  const request = payload.value as DecorationFlagsRequest;
  // FLAG bit-field: closable=1, maximizable=2, minimizable=4, resizable=8 (max 15).
  if (
    !isWindowId(request?.windowId) ||
    !isSafeInteger(request?.flags) ||
    request.flags < 0 ||
    request.flags > 15
  ) {
    throw new Error("set-decoration-flags requires a valid windowId and flags in [0, 15]");
  }
  return request;
}

interface WindowMoveResponse {
  startMoving: boolean;
}

/** One host-scoped implementation. Repeated calls are isolated by the platform window id. */
export class WindowPlugin extends AsyncPluginBase {
  readonly id = "ohos.window";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];
  private readonly prompts: PromptDialogs = new PromptDialogs();
  private readonly windows: Map<number, window.Window> = new Map();
  private removeCloseInterceptor?: () => void;

  onComponentTouch(event: BridgeComponentTouchEvent, context: BridgePluginContext): void {
    if (
      !context.isActive() ||
      (event.touch.type !== TouchType.Down && event.touch.type !== TouchType.Move)
    ) {
      return;
    }
    const response = context.invokeNativeSync(
      "move-requested",
      MOVE_REQUESTED_TYPE,
      MOVE_RESPONSE_TYPE,
      { windowId: event.windowId },
    ) as WindowMoveResponse;
    if (typeof response?.startMoving !== "boolean") {
      throw new Error("Invalid window move response");
    }
    if (response.startMoving) {
      // The platform needs the current pointer callback to capture subsequent movement.
      event.window.startMoving().catch((error: Error) => {
        hilog.error(DOMAIN, TAG, "Window move failed: %{public}s", String(error));
      });
    }
  }

  override onLifecycle(event: BridgeLifecycleEvent, context: BridgePluginHookContext): void {
    if (event.kind === "window-stage-create") {
      this.removeCloseInterceptor?.();
      this.removeCloseInterceptor = WindowManager.getInstance().registerCloseRequestInterceptor(
        (windowId: number): boolean => {
          if (!context.isActive()) {
            return false;
          }
          try {
            const response = context.invokeNativeSync(
              "close-requested",
              CLOSE_REQUESTED_TYPE,
              CLOSE_RESPONSE_TYPE,
              { windowId },
            ) as WindowCloseResponse;
            if (typeof response?.preventClose !== "boolean") {
              throw new Error("Invalid window close response");
            }
            return response.preventClose;
          } catch (error) {
            hilog.error(DOMAIN, TAG, "Window close request failed: %{public}s", String(error));
            return true;
          }
        },
      );
    } else if (event.kind === "window-stage-destroy") {
      this.removeCloseInterceptor?.();
      this.removeCloseInterceptor = undefined;
    }
  }

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    this.assertCallActive(context);
    if (action === "get-window-stack") {
      if (payload.typeName !== "ohos.window.StackRequest" || typeof payload.value !== "object") {
        throw new Error("get-window-stack requires ohos.window.StackRequest");
      }
      const request = payload.value as WindowStackRequest;
      if (
        !isWindowId(request.displayId) ||
        !Array.isArray(request.windowIds) ||
        request.windowIds.some((id: number) => !isWindowId(id))
      ) {
        throw new Error("Invalid window stack request");
      }
      const aliases: Map<number, number> = new Map();
      for (const id of request.windowIds) {
        if (WindowManager.getInstance().isWindowCreationDeferred(id)) {
          continue;
        }
        try {
          const nativeWindow = await this.requireWindow(id, context);
          aliases.set(nativeWindow.getWindowProperties().id, id);
        } catch (error) {
          hilog.warn(
            DOMAIN,
            TAG,
            "get-window-stack skipped window %{public}d: %{public}s",
            id,
            String(error),
          );
        }
      }
      if (deviceInfo.sdkApiVersion < 14) {
        throw new Error("get-window-stack requires API 14 or later");
      }
      // Negative/omitted coordinates query all visible windows belonging to this app.
      const ordered = await window.getWindowsByCoordinate(request.displayId);
      this.assertCallActive(context);
      const ids: number[] = [];
      for (const win of ordered) {
        const id = aliases.get(win.getWindowProperties().id);
        if (id !== undefined && !ids.includes(id)) {
          ids.push(id);
        }
      }
      return { typeName: "ohos.window.StackResponse", value: { windowIds: ids } };
    }

    if (action === "show-prompt") {
      if (payload.typeName !== "ohos.window.PromptRequest" || typeof payload.value !== "object") {
        throw new Error("show-prompt requires ohos.window.PromptRequest");
      }
      const request = payload.value as WindowPromptRequest;
      if (!isWindowId(request?.windowId)) {
        throw new Error("Invalid prompt window");
      }
      const index = await this.prompts.show(
        await this.requireWindow(request.windowId, context),
        request,
        context,
      );
      this.assertCallActive(context);
      return { typeName: "ohos.window.PromptResponse", value: { index } };
    }

    if (action === "get-avoid-area") {
      const request = parseAvoidAreaRequest(payload);
      try {
        const areaType = request.areaType as window.AvoidAreaType;
        const response = new AvoidAreaResponse(context.getWindow().getWindowAvoidArea(areaType));
        return { typeName: AVOID_AREA_RESPONSE_TYPE, value: response };
      } catch (error) {
        throw new Error(`Unable to get window avoid area: ${String(error)}`);
      }
    }

    if (action === "create-os-window") {
      const request = parseCreateRequest(payload);
      hilog.info(
        DOMAIN,
        TAG,
        "create-os-window bounds x=%{public}d y=%{public}d w=%{public}d h=%{public}d",
        request.x,
        request.y,
        request.width,
        request.height,
      );
      let created: window.Window | undefined;
      try {
        created = await context.getWindowStage().createSubWindow(request.name.trim());
        this.assertCallActive(context);
        await created.resize(request.width, request.height);
        const position = await WindowManager.getInstance().resolveWindowPosition(
          created,
          request.x,
          request.y,
        );
        await created.moveWindowTo(position.x, position.y);
        created.setWindowDecorVisible(request.decorations);
        const backgroundColor = request.transparent
          ? "#00000000"
          : this.colorString(request.backgroundColor ?? 0xffffffff);
        created.setWindowBackgroundColor(backgroundColor);
        // Float sub-windows also have a window container layer. Without making
        // it transparent, an opaque container sits between the window background
        // and ArkUI content — blocking backgroundBlurStyle from sampling through
        // the transparent window (vibrancy/frosted glass effect invisible).
        if (request.transparent && deviceInfo.sdkApiVersion >= 20) {
          try {
            created.setWindowContainerColor(
              "#00000000",
              WindowManager.getInstance().inactiveContainerColor(created, 0),
            );
          } catch (containerErr) {
            const error = containerErr as BusinessError;
            if (error.code !== 801) {
              hilog.warn(DOMAIN, TAG, "setWindowContainerColor failed: %{public}s", String(error));
            }
          }
        }
        await created.showWindow();
        this.assertCallActive(context);
        // showWindow() can reset a newly created float window to the origin.
        // Apply the requested GPUI bounds after the window is visible.
        await created.moveWindowTo(position.x, position.y);
        this.assertCallActive(context);
        const actualRect = created.getWindowProperties().windowRect;
        hilog.info(
          DOMAIN,
          TAG,
          "create-os-window shown at x=%{public}d y=%{public}d",
          actualRect.left,
          actualRect.top,
        );
        const windowId = created.getWindowProperties().id;
        if (!isWindowId(windowId)) {
          throw new Error(`createSubWindow returned invalid window id '${windowId}'`);
        }
        const replaced = this.windows.get(windowId);
        if (replaced !== undefined && replaced !== created) {
          await replaced.destroyWindow();
        }
        this.windows.set(windowId, created);
        return { typeName: CREATE_RESPONSE_TYPE, value: new WindowCreateResponse(windowId) };
      } catch (error) {
        if (created !== undefined) {
          try {
            await created.destroyWindow();
          } catch {}
        }
        throw new Error(`createSubWindow failed: ${String(error)}`);
      }
    }

    if (action === "set-decorations") {
      const request = parseDecorationsRequest(payload);
      const win = await this.requireWindow(request.windowId, context);
      try {
        const manager = WindowManager.getInstance();
        if (manager.isUIAbilityMainWindow(request.windowId) || this.windows.has(request.windowId)) {
          win.setWindowDecorVisible(request.decorations);
          if (manager.isUIAbilityMainWindow(request.windowId) && deviceInfo.sdkApiVersion >= 14) {
            // The main window can retain its three-button overlay after its title bar is hidden.
            win.setWindowTitleButtonVisible(
              request.decorations,
              request.decorations,
              request.decorations,
            );
          }
        } else {
          manager.setDecorations(request.windowId, request.decorations);
        }
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (error) {
        throw new Error(`set-decorations failed: ${String(error)}`);
      }
    }

    if (action === "set-fullscreen") {
      const request = parseFullscreenRequest(payload);
      const win = await this.requireWindow(request.windowId, context);
      await WindowManager.getInstance().setFullscreenAsync(request.windowId, request.on, {
        window: win,
        beforeRun: (): void => this.assertCallActive(context),
      });
      this.assertCallActive(context);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "set-background-color") {
      const request = parseColorRequest(payload);
      const win = await this.requireWindow(request.windowId, context);
      try {
        const color = this.colorString(request.color);
        win.setWindowBackgroundColor(color);
        if (
          WindowManager.getInstance().isUIAbilityMainWindow(request.windowId) &&
          deviceInfo.sdkApiVersion >= 20
        ) {
          // The main window has a separate container layer. A transparent content
          // background alone leaves that layer opaque and hides the blur beneath.
          try {
            win.setWindowContainerColor(
              color,
              WindowManager.getInstance().inactiveContainerColor(win, request.color),
            );
          } catch (containerError) {
            if ((containerError as BusinessError).code !== 801) {
              throw containerError as Error;
            }
            hilog.debug(
              DOMAIN,
              TAG,
              "setWindowContainerColor unavailable; window background applied",
            );
          }
        }
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (error) {
        throw new Error(`set window background failed: ${String(error)}`);
      }
    }

    if (action === "set-blur") {
      const request = parseBlurRequest(payload);
      await this.requireWindow(request.windowId, context);
      hilog.info(
        DOMAIN,
        TAG,
        "set-blur: ENTER windowId=%{public}d radius=%{public}f",
        Number(request.windowId),
        request.radius,
      );
      // Refresh both WebView and the native XComponent background layer.
      WindowManager.getInstance().applyWindowBlur(request.windowId, request.radius);
      hilog.info(DOMAIN, TAG, "set-blur: applyWindowBlur returned, ack=true");
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "focus") {
      const request = parseWindowIdRequest(payload);
      const manager = WindowManager.getInstance();
      manager.startDeferredWindowCreation(request.windowId);
      const win = await this.requireWindow(request.windowId, context);
      try {
        if (manager.isUIAbilityMainWindow(request.windowId)) {
          await manager.restoreWindow(request.windowId, {
            window: win,
            onlyIfMinimized: true,
            focus: true,
            beforeRun: (): void => this.assertCallActive(context),
          });
        } else {
          await manager.serializeOp(request.windowId, async (): Promise<void> => {
            this.assertCallActive(context);
            // showWindow also raises independent child windows and restores hidden ones.
            // raiseToAppTop does not change their stacking when the parent constraint is loosened.
            if (deviceInfo.sdkApiVersion >= 20) {
              await win.showWindow({ focusOnShow: true });
            } else {
              await win.showWindow();
            }
          });
        }
        this.assertCallActive(context);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (error) {
        throw new Error(`focus failed: ${String(error)}`);
      }
    }

    if (action === "set-focusable") {
      const request = parseFocusableRequest(payload);
      const win = await this.requireWindow(request.windowId, context);
      try {
        await win.setFocusable(request.focusable);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (error) {
        throw new Error(`setFocusable failed: ${String(error)}`);
      }
    }

    if (action === "set-touchable") {
      const request = parseTouchableRequest(payload);
      const win = await this.requireWindow(request.windowId, context);
      try {
        await win.setWindowTouchable(request.touchable);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (error) {
        throw new Error(`set-touchable failed: ${String(error)}`);
      }
    }

    if (action === "move-to") {
      const request = parseMoveRequest(payload);
      const win = await this.requireWindow(request.windowId, context);
      try {
        await win.moveWindowTo(request.x, request.y);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (error) {
        throw new Error(`moveWindowTo failed: ${String(error)}`);
      }
    }

    if (action === "resize") {
      const request = parseResizeRequest(payload);
      const win = await this.requireWindow(request.windowId, context);
      try {
        await win.resize(request.width, request.height);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (error) {
        throw new Error(`resize failed: ${String(error)}`);
      }
    }

    if (action === "minimize") {
      return await this.windowCommand("minimize", payload, context);
    }
    if (action === "maximize") {
      return await this.windowCommand("maximize", payload, context);
    }
    if (action === "restore") {
      return await this.windowCommand("restore", payload, context);
    }
    if (action === "recover") {
      return await this.windowCommand("recover", payload, context);
    }
    if (action === "show") {
      return await this.windowCommand("show", payload, context);
    }
    if (action === "destroy-window") {
      return await this.windowCommand("destroy-window", payload, context);
    }
    if (action === "is-maximized") {
      return this.windowState("is-maximized", payload, context);
    }
    if (action === "is-minimized") {
      return this.windowState("is-minimized", payload, context);
    }

    if (action === "set-topmost") {
      // Delegates to WindowManager.setWindowTopmost (API14 guard + WINDOW_TOPMOST
      // permission handling live there, ported from upstream PR#45).
      const request = parseTopmostRequest(payload);
      WindowManager.getInstance().setWindowTopmost(request.windowId, request.topmost);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "set-title") {
      // Delegates to WindowManager.setWindowTitle (API9+, main window + Float sub-windows).
      const request = parseTitleRequest(payload);
      WindowManager.getInstance().setWindowTitle(request.windowId, request.title);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "set-limits") {
      // Delegates to WindowManager.setWindowLimits (API11+, px, 0 = no limit).
      const request = parseLimitsRequest(payload);
      WindowManager.getInstance().setWindowLimits(
        request.windowId,
        request.minWidth,
        request.minHeight,
        request.maxWidth,
        request.maxHeight,
      );
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "request-user-attention") {
      // OHOS has no window-layer requestAttention API; emulate via a notification
      // (upstream PR#45). Fire-and-forget: publish failure is non-fatal and the
      // 1600004 (notification disabled) path pops the system authorization dialog
      // then retries. Unlike the old ArkHelper version we run in an async bridge
      // context, so hilog is safe everywhere here.
      const request = parseWindowIdRequest(payload);
      const notifId = ++attentionNotifId;
      const abilityInfo = context.abilityContext.abilityInfo;
      let appLabel = abilityInfo.label || abilityInfo.bundleName;
      if (abilityInfo.labelId > 0) {
        try {
          appLabel = context.abilityContext.resourceManager.getStringSync(abilityInfo.labelId);
        } catch (error) {
          hilog.warn(
            DOMAIN,
            TAG,
            "request-user-attention: app label lookup failed: %{public}s",
            String(error),
          );
        }
      }
      const notification: notificationManager.NotificationRequest = {
        id: notifId,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: appLabel, text: "请查看应用窗口" },
        },
      };
      const doPublish = async (retry: boolean): Promise<void> => {
        try {
          await notificationManager.publish(notification);
          hilog.info(
            DOMAIN,
            TAG,
            "request-user-attention: published OK (id=%{public}d, window=%{public}d)",
            notifId,
            request.windowId,
          );
        } catch (err) {
          const code = (err as BusinessError).code ?? -1;
          hilog.warn(
            DOMAIN,
            TAG,
            "request-user-attention: publish failed id=%{public}d code=%{public}s",
            notifId,
            String(code),
          );
          // 1600004 = notification not enabled → pop the system authorization
          // dialog (requestEnableNotification) and retry once.
          if (code === 1600004 && !retry) {
            try {
              await notificationManager.requestEnableNotification(context.abilityContext);
              hilog.info(
                DOMAIN,
                TAG,
                "request-user-attention: enabled, retry publish (id=%{public}d)",
                notifId,
              );
              await doPublish(true);
            } catch (e2) {
              hilog.warn(
                DOMAIN,
                TAG,
                "request-user-attention: requestEnableNotification failed: %{public}s",
                JSON.stringify(e2),
              );
            }
          }
        }
      };
      void doPublish(false);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "set-ime-position") {
      // Notifies the IME of the cursor rect via updateCursor (API10+). tao passes
      // physical pixels; CursorInfo left/top are px too — pass through directly.
      // Requires a focused editor (an HTML input counts — ArkWeb goes through the
      // system IME framework); without one the call fails with 12800009, which is
      // normal for any app. D3.8: awaits updateCursor and returns the result
      // directly instead of the old ArkHelper poll/getImePositionResult scheme.
      const request = parseImePositionRequest(payload);
      const cursorInfo: ESObject = {
        left: Math.round(request.x),
        top: Math.round(request.y),
        width: 1, // cursor width (px)
        height: 24, // cursor height (px, approximates line height)
      };
      try {
        await inputMethod.getController().updateCursor(cursorInfo);
        hilog.info(
          DOMAIN,
          TAG,
          "set-ime-position: updateCursor OK window=%{public}d x=%{public}d y=%{public}d",
          request.windowId,
          request.x,
          request.y,
        );
        return {
          typeName: IME_POSITION_RESPONSE_TYPE,
          value: new ImePositionResponse(true, 0, "OK"),
        };
      } catch (error) {
        const code = (error as BusinessError).code ?? -1;
        // 12800009 = input method client detached — no focused editor; caller decides severity.
        hilog.warn(
          DOMAIN,
          TAG,
          "set-ime-position: updateCursor failed code=%{public}s",
          String(code),
        );
        return {
          typeName: IME_POSITION_RESPONSE_TYPE,
          value: new ImePositionResponse(false, code as number, String(error)),
        };
      }
    }

    if (action === "set-draggable") {
      // enableDrag (API20+) — allow/forbid edge-drag resizing. The bridge context
      // propagates errors cleanly, so unsupported API levels surface as a real
      // error instead of the old ArkHelper no-op.
      const request = parseDraggableRequest(payload);
      if (deviceInfo.sdkApiVersion < 20) {
        throw new Error(`set-draggable requires API20+, current ${deviceInfo.sdkApiVersion}`);
      }
      const win = WindowManager.getInstance().getWindow(request.windowId);
      if (!win) {
        throw new Error(`set-draggable: window ${request.windowId} not found`);
      }
      try {
        await win.enableDrag(request.enable);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (error) {
        throw new Error(`set-draggable failed: ${String(error)}`);
      }
    }

    if (action === "set-keep-screen-on") {
      const request = parseKeepScreenOnRequest(payload);
      const win = WindowManager.getInstance().getWindow(request.windowId);
      if (!win) {
        throw new Error(`set-keep-screen-on: window ${request.windowId} not found`);
      }
      await win.setWindowKeepScreenOn(request.on);
      this.assertCallActive(context);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "get-real-window-id") {
      // Resolves tao's placeholder windowId (0 = main window) to the REAL OHOS
      // window id (getWindowProperties().id) required by native
      // OH_WindowManager_* C APIs (e.g. the cursor-grab FFI).
      const request = parseWindowIdRequest(payload);
      const realId = WindowManager.getInstance().getRealWindowId(request.windowId);
      if (realId < 0) {
        throw new Error(`get-real-window-id: window ${request.windowId} not found`);
      }
      return { typeName: REAL_WINDOW_ID_RESPONSE_TYPE, value: new RealWindowIdResponse(realId) };
    }

    if (action === "set-window-icon") {
      await setWindowIcon(payload, context);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }
    if (action === "set-custom-cursor") {
      const request = parseCustomCursor(payload);
      const win = await this.requireWindow(request.windowId, context);
      await WindowPointer.setCustom(win, request, (): void => this.assertCallActive(context));
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "set-cursor-icon") {
      const request = parseCursorIconRequest(payload);
      const win = await this.requireWindow(request.windowId, context);
      WindowPointer.setStyle(win, request.style);
      this.assertCallActive(context);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "set-cursor-visible") {
      const request = parseCursorVisibleRequest(payload);
      // The caller serializes visibility changes using this acknowledgement.
      // Returning before native completion can restore a cursor after newer input.
      let accepted = true;
      try {
        await WindowManager.getInstance().setPointerVisible(request.visible);
      } catch (error) {
        if ((error as BusinessError).code !== 801) {
          throw error as Error;
        }
        accepted = false;
      }
      this.assertCallActive(context);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(accepted) };
    }

    if (action === "set-decoration-flags") {
      // Applies the decoration flag bit-field (closable/maximizable/minimizable/
      // resizable) to a Float sub-window's LocalStorage. The UIAbility main
      // window is a no-op (its decorations are system-managed) — WindowManager
      // logs and returns, still acknowledged.
      const request = parseDecorationFlagsRequest(payload);
      WindowManager.getInstance().setDecorationFlags(request.windowId, request.flags);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    throw new Error(`Unsupported ohos.window action '${action}'`);
  }

  private async windowCommand(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    const request = parseWindowIdRequest(payload);

    // destroy-window is idempotent: a window closed via the notify_window_close
    // path (FloatPage ✕ button: removeWindow + destroyWindow; or system X:
    // aboutToDisappear) is already destroyed by the time the Rust drain's
    // on_window_close spawns its safety destroy_window bridge call. requireWindow
    // would throw "Unknown OS sub-window" for those — instead soft-lookup and
    // treat already-gone as success, so the safety spawn is a clean no-op rather
    // than an error-log every close. See doc/OHOS窗口遗留问题.md (问题一).
    if (action === "destroy-window") {
      if (request.windowId === 0) {
        throw new Error("Cannot destroy the main Ability window (id 0)");
      }
      const manager = WindowManager.getInstance();
      manager.cancelDeferredWindowCreation(request.windowId);
      await manager.waitForWindowCreation(request.windowId);
      this.assertCallActive(context);
      if (manager.isUIAbilityMainWindow(request.windowId)) {
        // Main windows belong to a UIAbility; destroyWindow is only valid for child windows.
        await manager.destroyWindow(request.windowId);
      } else {
        const existing = this.windows.get(request.windowId) ?? manager.getWindow(request.windowId);
        if (existing !== undefined) {
          await existing.destroyWindow();
          this.windows.delete(request.windowId);
        }
      }
      this.assertCallActive(context);
      // else: already destroyed — idempotent success
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    const manager = WindowManager.getInstance();
    if (action === "show" || action === "restore") {
      manager.startDeferredWindowCreation(request.windowId);
    }
    const win = await this.requireWindow(request.windowId, context);
    try {
      if (
        action === "restore" ||
        (action === "show" && manager.isUIAbilityMainWindow(request.windowId))
      ) {
        await manager.restoreWindow(request.windowId, {
          window: win,
          onlyIfMinimized: action === "show",
          beforeRun: (): void => this.assertCallActive(context),
        });
      } else {
        await manager.serializeOp(request.windowId, async (): Promise<void> => {
          this.assertCallActive(context);
          const dynamic: ESObject = this.dynamic(win);
          if (action === "minimize") {
            await (dynamic.minimize() as Promise<void>);
          } else if (action === "maximize") {
            // Use FOLLOW_APP_IMMERSIVE_SETTING (not the default ENTER_IMMERSIVE) to
            // preserve the existing fullscreen layout mode. ENTER_IMMERSIVE causes a
            // layout gap (white bar at bottom) after recover().
            // Snapshot the floating rect first: WMS recover() re-anchors the floating
            // position to the pointer (GetFullScreenToFloatingRect), so the paired
            // recover below must moveTo() back — see WindowManager.preMaximizeRects.
            // Cannot delegate to WindowManager.maximizeWindow (fire-and-forget) without
            // losing this bridge's await-completion semantics (callers immediately
            // query is-maximized afterwards).
            manager.snapshotPreMaximizeRect(request.windowId, win);
            await win.maximize(window.MaximizePresentation.FOLLOW_APP_IMMERSIVE_SETTING);
          } else if (action === "recover") {
            await (dynamic.recover() as Promise<void>);
            // Restore the pre-maximize position snapshotted above (WMS recover()
            // pointer-anchors the floating rect). Best-effort — recover already
            // succeeded.
            await manager.restorePreMaximizeRect(request.windowId, win);
            // NOTE: Do NOT call showWindow() after recover() — recover() already makes
            // the window visible, and showWindow() resets the window position to centered
            // state, causing the window to jump to the center of the screen.
          } else if (action === "show") {
            // A hidden window can still report its pre-placement rectangle. The
            // OS applies its pending move on show; replaying that snapshot loses it.
            const focusOnShow = manager.focusOnShow(request.windowId);
            if (deviceInfo.sdkApiVersion >= 20 && focusOnShow !== undefined) {
              await win.showWindow({ focusOnShow });
            } else {
              await win.showWindow();
            }
          }
        });
      }
      this.assertCallActive(context);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    } catch (error) {
      throw new Error(`${action} failed: ${String(error)}`);
    }
  }

  private async windowState(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    const request = parseWindowIdRequest(payload);
    const win = await this.requireWindow(request.windowId, context);
    try {
      const status = win.getWindowStatus();
      const value: boolean =
        action === "is-maximized"
          ? status === window.WindowStatusType.MAXIMIZE
          : status === window.WindowStatusType.MINIMIZE;
      return { typeName: STATE_RESPONSE_TYPE, value: new WindowStateResponse(value) };
    } catch (error) {
      throw new Error(`${action} failed: ${String(error)}`);
    }
  }

  private async requireWindow(
    windowId: number,
    context: BridgeCallContext,
  ): Promise<window.Window> {
    this.assertCallActive(context);
    if (windowId === 0) {
      const hostWindow = context.getWindow?.();
      if (hostWindow !== undefined) {
        return hostWindow;
      }
    }
    const manager = WindowManager.getInstance();
    // Rust can enqueue operations while createSubWindow is awaiting ArkUI content loading.
    await manager.waitForWindowCreation(windowId);
    this.assertCallActive(context);
    const win = this.windows.get(windowId) ?? manager.getWindow(windowId);
    if (win === undefined) {
      throw new Error(`Unknown OS window '${windowId}' for this plugin instance`);
    }
    return win;
  }

  private assertCallActive(context: BridgeCallContext): void {
    if (!context.isActive()) {
      throw new Error("Window bridge call is no longer active");
    }
  }

  private colorString(color: number): string {
    return `#${(color >>> 0).toString(16).padStart(8, "0")}`;
  }

  override async onDispose(): Promise<void> {
    this.removeCloseInterceptor?.();
    this.removeCloseInterceptor = undefined;
    await this.prompts.dispose();
    const windows = Array.from(this.windows.values());
    this.windows.clear();
    await Promise.all(
      windows.map(async (win: window.Window): Promise<void> => {
        try {
          await win.destroyWindow();
        } catch {}
      }),
    );
  }

  private dynamic(win: window.Window): ESObject {
    return win as ESObject;
  }
}
