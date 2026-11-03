import {
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  SyncPluginBase,
} from "@ohos-rs/ability";
import { liveWebviewController } from "./WebviewPlugin";

const GET_URL_REQUEST_TYPE = "ohos.webview.UrlGetRequest";
const GET_URL_RESPONSE_TYPE = "ohos.webview.UrlGetResponse";

interface GetUrlRequest {
  id: string;
}

class GetUrlResponse {
  readonly url: string;

  constructor(url: string) {
    this.url = url;
  }
}

function parseGetUrlRequest(payload: BridgeTypedValue): GetUrlRequest {
  if (payload.typeName !== GET_URL_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(
      `ohos.webview-url.get-url requires bridge type ${GET_URL_REQUEST_TYPE}`,
    );
  }
  const request = payload.value as GetUrlRequest;
  if (typeof request?.id !== "string" || request.id.length === 0) {
    throw new Error("get-url.id must be a non-empty string");
  }
  return request;
}

/**
 * Synchronous webview-URL bridge plugin for ArkTS (#192).
 *
 * `WebviewController.getUrl()` is a synchronous ArkTS API, but the async
 * `ohos.webview` plugin cannot serve it to a main-thread caller (the TSFN
 * round-trip needs that same main thread to pump, i.e. deadlock), so the sync
 * read lives in this dedicated `MainThreadSync` plugin: the call always
 * executes on the UI thread, exactly where the controller API requires it.
 * The controller itself is resolved from the module-level live-controller
 * index maintained by `WebviewPlugin.ets` (register on attach, unregister on
 * remove), mirroring `WebviewCookiePlugin` in every mechanical respect.
 *
 * Plugin ID: `ohos.webview-url` (matches the Rust `WebviewUrlBridgePlugin`)
 * Required contexts: none
 */
export class WebviewUrlPlugin extends SyncPluginBase {
  readonly id = "ohos.webview-url";
  readonly requires: BridgeContextRequirement[] = [];

  invokeSync(
    action: string,
    payload: BridgeTypedValue,
    _context: BridgeCallContext,
  ): BridgeTypedValue {
    if (action === "get-url") {
      const request = parseGetUrlRequest(payload);
      const controller = liveWebviewController(request.id);
      if (controller === undefined) {
        throw new Error(`Unknown WebView controller '${request.id}'`);
      }
      try {
        const url = controller.getUrl();
        return {
          typeName: GET_URL_RESPONSE_TYPE,
          value: new GetUrlResponse(url),
        };
      } catch (error) {
        throw new Error(`Unable to get WebView URL: ${String(error)}`);
      }
    }

    throw new Error(`Unsupported ohos.webview-url action '${action}'`);
  }
}
