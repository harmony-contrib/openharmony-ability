import { deviceInfo } from "@kit.BasicServicesKit";
import {
  BridgeCallContext,
  BridgeTypedValue,
  BridgePluginContext,
  BridgePluginFactory,
  MainThreadSyncBridgePlugin,
} from "@ohos-rs/ability";

const VERSION_REQUEST_TYPE = "ohos.version.VersionRequest";
const VERSION_RESPONSE_TYPE = "ohos.version.VersionResponse";

interface VersionRequest {
  syscap?: string | null;
}

class VersionResponse {
  readonly value: number;
  readonly result: boolean | null;

  constructor(value: number, result: boolean | null) {
    this.value = value;
    this.result = result;
  }
}

function parseVersionRequest(payload: BridgeTypedValue): VersionRequest {
  if (payload.typeName !== VERSION_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.version requires bridge type ${VERSION_REQUEST_TYPE}`);
  }
  return payload.value as VersionRequest;
}

function requireSyscap(request: VersionRequest): string {
  if (typeof request.syscap !== "string" || !request.syscap.trim()) {
    throw new Error("can-i-use.syscap must be a non-empty string");
  }
  return request.syscap.trim();
}

class VersionPlugin implements MainThreadSyncBridgePlugin {
  readonly id = "ohos.version";
  readonly version = 1;
  readonly execution = "sync-main-thread" as const;
  readonly requires = ["ability"] as const;

  invokeSync(
    action: string,
    payload: BridgeTypedValue,
    _context: BridgeCallContext,
  ): BridgeTypedValue {
    const request = parseVersionRequest(payload);
    if (action === "get-sdk-api-version") {
      return {
        typeName: VERSION_RESPONSE_TYPE,
        value: new VersionResponse(deviceInfo.sdkApiVersion, null),
      };
    }
    if (action === "get-distribution-api-version") {
      return {
        typeName: VERSION_RESPONSE_TYPE,
        value: new VersionResponse(deviceInfo.distributionOSApiVersion, null),
      };
    }
    if (action === "can-i-use") {
      const syscap = requireSyscap(request);
      let result = false;
      try {
        result = canIUse(syscap);
      } catch {
        result = false;
      }
      return { typeName: VERSION_RESPONSE_TYPE, value: new VersionResponse(0, result) };
    }
    if (action === "is-desktop-device") {
      const result = deviceInfo.deviceType === "2in1";
      return { typeName: VERSION_RESPONSE_TYPE, value: new VersionResponse(0, result) };
    }
    throw new Error(`Unsupported ohos.version action '${action}'`);
  }
}

export function createVersionPlugin(): BridgePluginFactory {
  return {
    id: "ohos.version",
    version: 1,
    execution: "sync-main-thread",
    requires: ["ability"],
    create: (_context: BridgePluginContext): MainThreadSyncBridgePlugin => new VersionPlugin(),
  };
}
