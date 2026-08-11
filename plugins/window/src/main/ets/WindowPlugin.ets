import window from "@ohos.window";
import {
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  SyncPluginBase,
} from "@ohos-rs/ability";

const AVOID_AREA_REQUEST_TYPE = "ohos.window.AvoidAreaRequest";
const AVOID_AREA_RESPONSE_TYPE = "ohos.window.AvoidAreaResponse";

interface AvoidAreaRequest {
  areaType: number;
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

export class WindowPlugin extends SyncPluginBase {
  readonly id = "ohos.window";
  readonly version = 2;
  readonly requires: BridgeContextRequirement[] = ["ui-context"];

  invokeSync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): BridgeTypedValue {
    if (action !== "get-avoid-area") {
      throw new Error(`Unsupported ohos.window action '${action}'`);
    }
    const request = parseAvoidAreaRequest(payload);
    try {
      const areaType = request.areaType as window.AvoidAreaType;
      const response = new AvoidAreaResponse(context.getWindow().getWindowAvoidArea(areaType));
      return { typeName: AVOID_AREA_RESPONSE_TYPE, value: response };
    } catch (error) {
      throw new Error(`Unable to get window avoid area: ${String(error)}`);
    }
  }
}
