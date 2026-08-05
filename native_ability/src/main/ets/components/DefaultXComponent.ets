import { NodeContent } from "@kit.ArkUI";
import { BridgeBindings, Module } from "../ability/type";
import { BridgeHostRegistry } from "../bridge/BridgeHost";
import {
  BridgeNodeSlot,
  BridgeNodeSlotController,
  BridgeNodeSlotRegistry,
  DEFAULT_PLUGIN_NODE_SLOT,
} from "../bridge/BridgeNodeSlot";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";

export const RouteName = "NativeAbility";

/**
 * Mounts only the Rust XComponent and generic bridge bindings. Platform capabilities deliberately
 * do not live here: a capability that needs ArkUI content (for example WebView) owns a separate
 * HAR host component and the application places that component in its own layout.
 */
@Component
export struct DefaultXComponent {
  moduleName: string = "";
  private rootSlot = new NodeContent();
  private pluginNodeController = new BridgeNodeSlotController(this.getUIContext());
  private pluginNodeSlot?: BridgeNodeSlot;
  private nativeModule?: Module;
  @StorageProp("bridgeSessionId") bridgeSessionId: string = "";
  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";

  private bindings: BridgeBindings = {
    bridgeInvoke: async (
      pluginId: string,
      pluginVersion: number,
      action: string,
      requestTypeName: string,
      responseTypeName: string,
      value: ESObject,
      timeoutMs: number,
    ): Promise<ESObject> => {
      return await BridgeHostRegistry.invokeAsync(
        this.bridgeSessionId,
        this.moduleName.trim(),
        pluginId,
        pluginVersion,
        action,
        requestTypeName,
        responseTypeName,
        value,
        timeoutMs,
      );
    },
    bridgeInvokeSync: (
      pluginId: string,
      pluginVersion: number,
      action: string,
      requestTypeName: string,
      responseTypeName: string,
      value: ESObject,
    ): ESObject => {
      return BridgeHostRegistry.invokeSync(
        this.bridgeSessionId,
        this.moduleName.trim(),
        pluginId,
        pluginVersion,
        action,
        requestTypeName,
        responseTypeName,
        value,
      );
    },
    // The Rust MainThreadScheduler executes its closure inside this TSFN callback before this
    // no-op function is invoked. It carries no capability-specific behavior.
    bridgeDispatch: (): void => {},
  };

  async aboutToAppear(): Promise<void> {
    const moduleName = this.moduleName.trim();
    if (!moduleName) {
      throw new Error("DefaultXComponent.moduleName is required");
    }

    const nativeModule = await NativeModuleLoader.load(moduleName, this.loadMode);
    this.nativeModule = nativeModule;
    // Idempotent fallback: NativeAbility.onCreate already attached the sink right after
    // module.init (same cached Module instance), so `ability`-only plugins can emit inbound
    // events on `ability-create`. Re-attaching here covers modules loaded without onCreate.
    BridgeHostRegistry.attachEventSink(
      this.bridgeSessionId,
      moduleName,
      (
        pluginId: string,
        event: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject => {
        const nativeModuleForSyncEvent = this.nativeModule;
        if (
          nativeModuleForSyncEvent === undefined ||
          typeof nativeModuleForSyncEvent.onBridgeSyncEvent !== "function"
        ) {
          throw new Error("Native module does not export onBridgeSyncEvent");
        }
        return nativeModuleForSyncEvent.onBridgeSyncEvent(
          pluginId,
          event,
          requestTypeName,
          responseTypeName,
          value,
        );
      },
    );
    nativeModule.render(this.bindings, this.rootSlot);

    // Attach the neutral node layer before UI-context activation. A plugin that needs an ArkUI
    // surface can therefore mount its own FrameNode during onInstall without DefaultXComponent
    // gaining any WebView- or capability-specific code.
    this.pluginNodeSlot = BridgeNodeSlotRegistry.attach(
      this.bridgeSessionId,
      moduleName,
      DEFAULT_PLUGIN_NODE_SLOT,
      this.getUIContext(),
      this.pluginNodeController,
    );

    // Rust must observe readiness before ArkTS plugin installation can emit an event.
    nativeModule.onBridgeLifecycle?.("ui-context-ready");
    await BridgeHostRegistry.setUiContext(this.bridgeSessionId, moduleName, this.getUIContext());
  }

  aboutToDisappear(): void {
    const moduleName = this.moduleName.trim();
    if (this.bridgeSessionId && moduleName) {
      const nativeModule = this.nativeModule;
      const pluginNodeSlot = this.pluginNodeSlot;
      this.pluginNodeSlot = undefined;
      BridgeHostRegistry.clearUiContext(this.bridgeSessionId, moduleName)
        .then(() => nativeModule?.onBridgeLifecycle?.("ui-context-destroy"))
        .catch(() => {})
        .finally(() => {
          if (pluginNodeSlot) {
            BridgeNodeSlotRegistry.detach(pluginNodeSlot);
          }
          BridgeHostRegistry.detachEventSink(this.bridgeSessionId, moduleName);
        });
    }
  }

  build() {
    Stack() {
      ContentSlot(this.rootSlot)
      // Keep the legacy overlay tree and its transparent hit-test policy intact.  Plugins only
      // replace the old WebView-specific controller with a neutral FrameNode mount point, so an
      // existing XComponent keeps its sizing, stacking, and input behaviour.
      Row() {
        Column() {
          NodeContainer(this.pluginNodeController)
            .height("100%")
            .width("100%")
        }.width("100%")
      }
      .height("100%")
      .hitTestBehavior(HitTestMode.Transparent)
    };
  }
}
