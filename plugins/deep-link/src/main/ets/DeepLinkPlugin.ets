import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

// ── Bridge type name contracts ────────────────────────────────────────────────
// These must match the Rust-side `impl_bridge_napi_type!` TYPE_NAME values.

const GET_URI_REQUEST_TYPE = "ohos.deep-link.GetUriRequest";
const GET_URI_RESPONSE_TYPE = "ohos.deep-link.GetUriResponse";

// ── AppStorage keys ───────────────────────────────────────────────────────────
// Populated by NativeAbility.ets:
//   - "initialWantUri": set once in onCreate(want) — the cold-start want.uri.
//   - "wantUri": set in onCreate(want) and updated in onNewWant(want) — the latest want.uri.

const INITIAL_WANT_URI_KEY = "initialWantUri";
const LATEST_WANT_URI_KEY = "wantUri";

class DeepLinkGetUriResponse {
  readonly uri: string | null;

  constructor(uri: string | null) {
    this.uri = uri;
  }
}

/**
 * Reads a URI string from `AppStorage`. Returns `null` for empty or missing values
 * so the Rust facade receives `Ok(None)` for normal (non-deep-link) launches.
 */
function readUri(storageKey: string): string | null {
  const uri = AppStorage.get<string>(storageKey);
  if (uri === undefined || uri === null || uri.length === 0) {
    return null;
  }
  return uri;
}

export class DeepLinkPlugin extends AsyncPluginBase {
  readonly id = "ohos.deep-link";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }

    if (action === "get-initial-uri") {
      expectBridgeRequestType(payload, "ohos.deep-link", action, GET_URI_REQUEST_TYPE);
      return {
        typeName: GET_URI_RESPONSE_TYPE,
        value: new DeepLinkGetUriResponse(readUri(INITIAL_WANT_URI_KEY)),
      };
    }

    if (action === "get-latest-uri") {
      expectBridgeRequestType(payload, "ohos.deep-link", action, GET_URI_REQUEST_TYPE);
      return {
        typeName: GET_URI_RESPONSE_TYPE,
        value: new DeepLinkGetUriResponse(readUri(LATEST_WANT_URI_KEY)),
      };
    }

    throw new Error(`Unsupported ohos.deep-link action '${action}'`);
  }
}
