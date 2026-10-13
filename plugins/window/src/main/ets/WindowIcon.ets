import { image } from "@kit.ImageKit";
import { deviceInfo } from "@kit.BasicServicesKit";
import { BridgeCallContext, BridgeTypedValue } from "@ohos-rs/ability";

interface WindowIconRequest {
  windowId: number;
  rgba: number[];
  size: number;
}

export async function setWindowIcon(
  payload: BridgeTypedValue,
  context: BridgeCallContext,
): Promise<void> {
  if (
    payload.typeName !== "ohos.window.WindowIconRequest" ||
    typeof payload.value !== "object" ||
    payload.value === null
  ) {
    throw new Error("set-window-icon requires ohos.window.WindowIconRequest");
  }
  const request = payload.value as WindowIconRequest;
  if (
    request.windowId !== 0 ||
    !Number.isInteger(request.size) ||
    request.size < 0 ||
    request.size > 1024 ||
    !Array.isArray(request.rgba) ||
    request.rgba.length !== request.size * request.size * 4 ||
    request.rgba.some((v: number): boolean => !Number.isInteger(v) || v < 0 || v > 255)
  ) {
    throw new Error("Invalid main-window RGBA icon");
  }
  if (
    deviceInfo.sdkApiVersion < 22 ||
    (deviceInfo.deviceType !== "2in1" && deviceInfo.deviceType !== "pc")
  ) {
    throw new Error("Runtime window icons require API 22+ on PC/2in1");
  }
  const ability = context.abilityContext;
  let pixels: image.PixelMap;
  if (request.size === 0) {
    const resourceId = ability.abilityInfo.iconId || ability.applicationInfo.iconId;
    const bytes = await ability.resourceManager.getMediaContent(resourceId);
    const source = image.createImageSource(bytes.buffer);
    try {
      pixels = await source.createPixelMap();
    } finally {
      await source.release();
    }
  } else {
    pixels = await image.createPixelMap(new Uint8Array(request.rgba).buffer, {
      size: { width: request.size, height: request.size },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.UNPREMUL,
      editable: false,
    });
  }
  try {
    if (!context.isActive()) throw new Error("Window icon call is no longer active");
    await ability.setMissionWindowIcon(pixels);
    if (!context.isActive()) throw new Error("Window icon call is no longer active");
  } finally {
    await pixels.release();
  }
}
