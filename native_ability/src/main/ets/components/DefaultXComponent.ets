import { NodeContent } from "@kit.ArkUI";
import { FrameNode, NodeController } from "@ohos.arkui.node";
import { UIContext } from "@ohos.arkui.UIContext";
import { BridgeBindings, Module } from "../ability/type";
import { BridgeHostRegistry, MAIN_WINDOW_KEY } from "../bridge/BridgeHost";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";

export const RouteName = "NativeAbility";

/**
 * Mounts only the Rust XComponent and generic bridge bindings. Platform capabilities deliberately
 * do not live here: a capability that needs ArkUI content (for example WebView) owns a plugin
 * and mounts its own FrameNode into the session root this component provides.
 *
 * Multi-window: each instance registers its own window surface under `windowKey` (`"main"` by
 * default). Sub-window pages place another `DefaultXComponent` with a unique `windowKey` (for
 * example `windowId`), and plugins address it through `BridgePluginContext.windowScope`.
 */
@Component
export struct DefaultXComponent {
  moduleName: string = "";
  /** Unique key of the window surface this instance owns; `"main"` is the default window. */
  @Prop windowKey: string = MAIN_WINDOW_KEY;
  private rootSlot = new NodeContent();
  private nodeController = new BridgeRootNodeController(this.getUIContext());
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

    // Create the window root eagerly (NodeContainer asks the controller lazily) so it exists
    // before `ui-context-ready`. Every plugin then mounts into this one tree without slots,
    // registries or readiness waiters. Attaching the `"main"` window emits `ui-context-ready`;
    // sub-window instances (unique `windowKey`) only register their own surface.
    const root = this.nodeController.makeNode(this.getUIContext());
    BridgeHostRegistry.attachWindow(
      this.bridgeSessionId,
      moduleName,
      this.windowKey,
      this.getUIContext(),
      root,
    );

    // Rust must observe readiness before ArkTS plugin installation can emit an event.
    if (this.windowKey === MAIN_WINDOW_KEY) {
      nativeModule.onBridgeLifecycle?.("ui-context-ready");
    }
  }

  aboutToDisappear(): void {
    const moduleName = this.moduleName.trim();
    if (this.bridgeSessionId && moduleName) {
      const nativeModule = this.nativeModule;
      const windowKey = this.windowKey;
      BridgeHostRegistry.detachWindow(this.bridgeSessionId, moduleName, windowKey)
        .then(() => {
          if (windowKey === MAIN_WINDOW_KEY) {
            nativeModule?.onBridgeLifecycle?.("ui-context-destroy");
          }
        })
        .catch(() => {})
        .finally(() => {
          this.nodeController.disposeRoot();
          if (windowKey === MAIN_WINDOW_KEY) {
            BridgeHostRegistry.detachEventSink(this.bridgeSessionId, moduleName);
          }
        });
    }
  }

  build() {
    Stack() {
      // ContentSlot stays below the plugin tree exactly as before: the XComponent/RS render root
      // is the base layer, and the session plugin tree overlays it with the legacy transparent
      // hit-test policy.
      ContentSlot(this.rootSlot)
      Row() {
        Column() {
          NodeContainer(this.nodeController)
            .height("100%")
            .width("100%")
        }.width("100%")
      }
      .height("100%")
      .hitTestBehavior(HitTestMode.Transparent)
    };
  }
}

/**
 * Owns the single session root FrameNode. Plugins never touch this controller directly; they
 * receive the root through `BridgePluginContext.getRootFrameNode()`.
 */
class BridgeRootNodeController extends NodeController {
  private root: FrameNode | null = null;
  private readonly uiContext: UIContext;

  constructor(uiContext: UIContext) {
    super();
    this.uiContext = uiContext;
  }

  makeNode(uiContext: UIContext): FrameNode {
    if (this.root === null) {
      this.root = new FrameNode(uiContext);
    }
    return this.root;
  }

  disposeRoot(): void {
    this.root?.dispose();
    this.root = null;
  }
}
