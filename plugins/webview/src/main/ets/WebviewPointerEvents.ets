import { BridgeTypedValue } from "@ohos-rs/ability";

export const POINTER_EVENTS_REQUEST_TYPE = "ohos.webview.PointerEventsRequest";
export const POINTER_EVENT_TYPE = "ohos.webview.PointerEvent";
export interface WebviewPointerEventsRequest {
  id: string;
  enabled: boolean;
}
export function parsePointerEvents(payload: BridgeTypedValue): WebviewPointerEventsRequest {
  if (
    payload.typeName !== POINTER_EVENTS_REQUEST_TYPE ||
    !payload.value ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`WebView requires ${POINTER_EVENTS_REQUEST_TYPE}`);
  }
  const request = payload.value as WebviewPointerEventsRequest;
  if (
    typeof request.id !== "string" ||
    request.id.trim().length === 0 ||
    typeof request.enabled !== "boolean"
  ) {
    throw new Error("WebView pointer events require an id and boolean enabled");
  }
  return request;
}

export class WebviewPointerEvent {
  readonly id: string;
  readonly nativeTag: string;
  readonly x: number;
  readonly y: number;
  readonly button: number;
  readonly modifiers: number;
  constructor(
    id: string,
    nativeTag: string,
    x: number,
    y: number,
    button: number,
    modifiers: number,
  ) {
    this.id = id;
    this.nativeTag = nativeTag;
    this.x = x;
    this.y = y;
    this.button = button;
    this.modifiers = modifiers;
  }
}

/** Passive observations only: never cancel propagation or ArkWeb's default input. */
export class WebviewPointerEvents {
  enabled = false;
  private readonly id: string;
  private readonly nativeTag: string;
  private readonly isCurrent: () => boolean;
  private readonly notify: (event: WebviewPointerEvent) => void;
  constructor(
    id: string,
    nativeTag: string,
    isCurrent: () => boolean,
    notify: (event: WebviewPointerEvent) => void,
  ) {
    this.id = id;
    this.nativeTag = nativeTag;
    this.isCurrent = isCurrent;
    this.notify = notify;
  }

  mouse(event: MouseEvent): void {
    if (event.action !== MouseAction.Press) return;
    let button: number;
    switch (event.button) {
      case MouseButton.Left:
        button = 0;
        break;
      case MouseButton.Right:
        button = 1;
        break;
      case MouseButton.Middle:
        button = 2;
        break;
      case MouseButton.Back:
        button = 3;
        break;
      case MouseButton.Forward:
        button = 4;
        break;
      default:
        return;
    }
    this.emit(event, event.x, event.y, button);
  }

  touch(event: TouchEvent): void {
    // Mouse input also generates touch events. Only the first touchscreen
    // contact represents a primary press; later fingers belong to the same gesture.
    if (
      event.type !== TouchType.Down ||
      event.source !== SourceType.TouchScreen ||
      event.touches.length !== 1
    )
      return;
    const point = event.changedTouches[0];
    if (!point || point.id !== event.touches[0].id) return;
    this.emit(event, point.x, point.y, 0);
  }

  private emit(event: BaseEvent, x: number, y: number, button: number): void {
    if (!this.enabled || !this.isCurrent() || !Number.isFinite(x) || !Number.isFinite(y)) return;
    let modifiers = 0;
    // Public pointer callbacks expose Ctrl/Alt/Shift only (API 12+), and
    // may throw for a stylus. Never keep the platform event beyond this call.
    if (event.getModifierKeyState) {
      const keys: string[] = ["Shift", "Ctrl", "Alt"];
      for (let index = 0; index < keys.length; index++) {
        try {
          if (event.getModifierKeyState([keys[index]])) modifiers |= 1 << index;
        } catch {}
      }
    }
    try {
      this.notify(new WebviewPointerEvent(this.id, this.nativeTag, x, y, button, modifiers));
    } catch (error) {
      console.error("WebView pointer notification failed: " + String(error));
    }
  }
}
