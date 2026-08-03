import process from "@ohos.process";
import {
  BridgeCallContext,
  BridgeTypedValue,
  BridgePluginContext,
  BridgePluginFactory,
  MainThreadSyncBridgePlugin,
} from "@ohos-rs/ability";

const TERMINATE_REQUEST_TYPE = "ohos.app_control.TerminateRequest";
const TERMINATE_RESPONSE_TYPE = "ohos.app_control.TerminateResponse";

interface TerminateRequest {
  code: number;
}

class TerminateResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

function parseTerminateRequest(payload: BridgeTypedValue): TerminateRequest {
  if (payload.typeName !== TERMINATE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.app-control.terminate requires bridge type ${TERMINATE_REQUEST_TYPE}`);
  }
  const request = payload.value as TerminateRequest;
  if (!Number.isInteger(request?.code)) {
    throw new Error("terminate.code must be an integer");
  }
  return request;
}

class AppControlPlugin implements MainThreadSyncBridgePlugin {
  readonly id = "ohos.app-control";
  readonly version = 1;
  readonly execution: "sync-main-thread" = "sync-main-thread";
  readonly requires: ["ability"] = ["ability"];

  invokeSync(
    action: string,
    payload: BridgeTypedValue,
    _context: BridgeCallContext,
  ): BridgeTypedValue {
    if (action !== "terminate") {
      throw new Error(`Unsupported ohos.app-control action '${action}'`);
    }
    const request = parseTerminateRequest(payload);
    const manager = new process.ProcessManager();
    manager.exit(request.code);
    return { typeName: TERMINATE_RESPONSE_TYPE, value: new TerminateResponse(true) };
  }
}

export function createAppControlPlugin(): BridgePluginFactory {
  return {
    id: "ohos.app-control",
    version: 1,
    execution: "sync-main-thread",
    requires: ["ability"],
    create: (_context: BridgePluginContext): MainThreadSyncBridgePlugin => new AppControlPlugin(),
  };
}
