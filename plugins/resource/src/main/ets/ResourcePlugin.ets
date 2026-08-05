import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeLifecycleEvent,
  BridgePluginContext,
  BridgeTypedValue,
} from "@ohos-rs/ability";

const RESOURCE_MANAGER_READY_EVENT = "resource-manager-ready";
const RESOURCE_MANAGER_REF_TYPE = "ohos.resource.ResourceManagerRef";
const RESOURCE_MANAGER_READY_RESPONSE_TYPE = "ohos.resource.ResourceManagerReadyResponse";

/**
 * Resource manager wrapper plugin.
 *
 * This wrapper owns only the HarmonyOS `resourceManager` platform object. It pushes the object
 * to Rust once, on `ability-create`: the inbound event sink is attached right after
 * `module.init` in `NativeAbility.onCreate`, so no UI render is required. Rust converts the
 * object to a native `NativeResourceManager` pointer inside the same N-API callback and
 * performs every subsequent read through the OpenHarmony C API — no ArkTS call is involved.
 *
 * The plugin is registered as a shared instance (`EagerPlugin`) because the native resource
 * manager is a process-wide singleton; per-session instances would be redundant.
 */
export class ResourcePlugin extends AsyncPluginBase {
  readonly id = "ohos.resource";
  readonly version = 1;
  readonly requires: BridgeContextRequirement[] = ["ability"];

  onLifecycle(event: BridgeLifecycleEvent, context: BridgePluginContext): void {
    if (event.kind !== "ability-create") {
      return;
    }
    const manager = context.abilityContext?.resourceManager;
    if (manager === undefined) {
      throw new Error("ohos.resource requires abilityContext.resourceManager");
    }
    context.invokeNativeSync(
      RESOURCE_MANAGER_READY_EVENT,
      RESOURCE_MANAGER_REF_TYPE,
      RESOURCE_MANAGER_READY_RESPONSE_TYPE,
      manager as ESObject,
    );
  }

  async invokeAsync(
    action: string,
    _request: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    throw new Error(`Unsupported ohos.resource action '${action}'`);
  }
}
