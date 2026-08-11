import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgePluginHookContext,
  BridgeTypedValue,
} from "@ohos-rs/ability";

const RESOURCE_MANAGER_READY_EVENT = "resource-manager-ready";
const RESOURCE_MANAGER_REF_TYPE = "ohos.resource.ResourceManagerRef";
const RESOURCE_MANAGER_READY_RESPONSE_TYPE = "ohos.resource.ResourceManagerReadyResponse";

/**
 * Resource manager wrapper plugin.
 *
 * This wrapper owns only the HarmonyOS `resourceManager` platform object. It pushes the object
 * to Rust once from `onInstall`: the inbound event sink is attached before Ability activation,
 * so no WindowStage or DefaultXComponent is required. Rust converts the
 * object to a native `NativeResourceManager` pointer inside the same N-API callback and
 * performs every subsequent read through the OpenHarmony C API — no ArkTS call is involved.
 *
 * The ArkTS wrapper remains Host/session-scoped. Its matching registered Rust plugin instance
 * owns the native manager, so repeated plugin instances do not overwrite each other's state.
 */
export class ResourcePlugin extends AsyncPluginBase {
  readonly id = "ohos.resource";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  override onInstall(context: BridgePluginHookContext): void {
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
