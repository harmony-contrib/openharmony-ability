import {
  BridgeCallContext,
  BridgeTypedValue,
  AsyncPluginBase,
  BridgeContextRequirement,
} from "@ohos-rs/ability";

const OPEN_REQUEST_TYPE = "ohos.url.OpenRequest";
const OPEN_RESPONSE_TYPE = "ohos.url.OpenResponse";

interface UrlOpenRequest {
  url: string;
}

class UrlOpenResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

function parseOpenRequest(payload: BridgeTypedValue): UrlOpenRequest {
  if (payload.typeName !== OPEN_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.url.open-url requires bridge type ${OPEN_REQUEST_TYPE}`);
  }
  const request = payload.value as UrlOpenRequest;
  if (typeof request.url !== "string" || !request.url.trim() || request.url.indexOf("://") < 0) {
    throw new Error("open-url.url must be an absolute URL with a scheme");
  }
  return request;
}

export class UrlPlugin extends AsyncPluginBase {
  readonly id = "ohos.url";
  readonly version = 1;
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (action !== "open-url") {
      throw new Error(`Unsupported ohos.url action '${action}'`);
    }
    const request = parseOpenRequest(payload);
    try {
      await context.abilityContext.openLink(request.url);
    } catch (error) {
      throw new Error(`openLink failed: ${String(error)}`);
    }
    if (!context.isActive()) {
      throw new Error("Ability was destroyed while the URL was being opened");
    }
    return { typeName: OPEN_RESPONSE_TYPE, value: new UrlOpenResponse(true) };
  }
}
