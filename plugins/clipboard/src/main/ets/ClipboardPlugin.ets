import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeTypedValue,
} from "@ohos-rs/ability";

/** Registration compatibility only. All clipboard data uses native OH_Pasteboard. */
export class ClipboardPlugin extends AsyncPluginBase {
  readonly id = "ohos.clipboard";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    _payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }
    throw new Error(
      `Unsupported ohos.clipboard action '${action}': use the native Rust clipboard facade`,
    );
  }
}
