import { BridgeTypedValue } from "@ohos-rs/ability";

export interface CustomCursorRequest {
  windowId: number;
  rgba: number[];
  width: number;
  height: number;
  hotspotX: number;
  hotspotY: number;
}
export function parseCustomCursor(payload: BridgeTypedValue): CustomCursorRequest {
  if (
    payload.typeName !== "ohos.window.CustomCursorRequest" ||
    typeof payload.value !== "object" ||
    payload.value === null
  ) {
    throw new Error("set-custom-cursor requires ohos.window.CustomCursorRequest");
  }
  const request = payload.value as CustomCursorRequest;
  if (
    !Number.isSafeInteger(request.windowId) ||
    request.windowId < 0 ||
    !Number.isInteger(request.width) ||
    request.width < 1 ||
    request.width > 256 ||
    !Number.isInteger(request.height) ||
    request.height < 1 ||
    request.height > 256 ||
    !Number.isInteger(request.hotspotX) ||
    request.hotspotX < 0 ||
    request.hotspotX >= request.width ||
    !Number.isInteger(request.hotspotY) ||
    request.hotspotY < 0 ||
    request.hotspotY >= request.height ||
    !Array.isArray(request.rgba) ||
    request.rgba.length !== request.width * request.height * 4 ||
    request.rgba.some((v: number): boolean => !Number.isInteger(v) || v < 0 || v > 255)
  ) {
    throw new Error("Invalid RGBA cursor dimensions, bytes or hotspot");
  }
  return request;
}
