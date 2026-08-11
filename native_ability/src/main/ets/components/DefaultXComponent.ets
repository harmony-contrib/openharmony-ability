import { NodeContent } from "@kit.ArkUI";
import { FrameNode, NodeController } from "@ohos.arkui.node";
import { UIContext } from "@ohos.arkui.UIContext";
import { BridgeBindings, Module } from "../ability/type";
import { BridgeHostRegistry, MAIN_WINDOW_KEY } from "../bridge/BridgeHost";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";

export const RouteName = "NativeAbility";

let nextRenderOwnerId: number = 1;

interface ComponentAttachment {
  sessionId: string;
  moduleName: string;
  windowKey: string;
  renderOwner: string;
  nativeModule: Module;
}

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
  @StorageProp("bridgeSessionId") bridgeSessionId: string = "";
  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";
  private appearanceGeneration: number = 0;
  private attachment?: ComponentAttachment;
  private releasePromise: Promise<void> = Promise.resolve();

  private createBindings(sessionId: string, moduleName: string): BridgeBindings {
    return {
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
          sessionId,
          moduleName,
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
          sessionId,
          moduleName,
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
  }

  async aboutToAppear(): Promise<void> {
    const generation = ++this.appearanceGeneration;
    await this.releasePromise;
    if (generation !== this.appearanceGeneration) {
      return;
    }
    const moduleName = this.moduleName.trim();
    if (!moduleName) {
      throw new Error("DefaultXComponent.moduleName is required");
    }

    const nativeModule = await NativeModuleLoader.load(moduleName, this.loadMode);
    if (generation !== this.appearanceGeneration) {
      return;
    }
    const sessionId = this.bridgeSessionId;
    if (!sessionId) {
      throw new Error(
        "DefaultXComponent cannot render before NativeAbility finishes creating its bridge session",
      );
    }
    // Idempotent fallback: NativeAbility.onCreate already attached the sink right after
    // module.init (same cached Module instance), so `ability`-only plugins can emit inbound
    // events on `ability-create`. Re-attaching here covers modules loaded without onCreate.
    BridgeHostRegistry.attachEventSink(
      sessionId,
      moduleName,
      (
        pluginId: string,
        event: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject => {
        if (typeof nativeModule.onBridgeSyncEvent !== "function") {
          throw new Error("Native module does not export onBridgeSyncEvent");
        }
        return nativeModule.onBridgeSyncEvent(
          pluginId,
          event,
          requestTypeName,
          responseTypeName,
          value,
        );
      },
      (kind: string): void => {
        nativeModule.onBridgeLifecycle?.(kind);
      },
    );
    const renderOwner = `${sessionId}:${moduleName}:${this.windowKey}:${nextRenderOwnerId++}`;
    nativeModule.render(this.createBindings(sessionId, moduleName), this.rootSlot, renderOwner);

    if (generation !== this.appearanceGeneration) {
      nativeModule.disposeRender?.(renderOwner);
      return;
    }

    // Create the window root eagerly (NodeContainer asks the controller lazily) so it exists
    // before `ui-context-ready`. Every plugin then mounts into this one tree without slots,
    // registries or readiness waiters. Attaching the `"main"` window emits `ui-context-ready`;
    // sub-window instances (unique `windowKey`) only register their own surface.
    const root = this.nodeController.makeNode(this.getUIContext());
    const attachment: ComponentAttachment = {
      sessionId,
      moduleName,
      windowKey: this.windowKey,
      renderOwner,
      nativeModule,
    };
    this.attachment = attachment;
    try {
      await BridgeHostRegistry.attachWindow(
        sessionId,
        moduleName,
        attachment.windowKey,
        this.getUIContext(),
        root,
      );
      if (generation !== this.appearanceGeneration) {
        await this.releasePromise;
      }
    } catch (error) {
      if (generation !== this.appearanceGeneration) {
        await this.releasePromise;
        return;
      }
      const release = this.releaseAttachment(attachment);
      this.releasePromise = release;
      await release;
      throw new Error(String(error));
    }
  }

  aboutToDisappear(): void {
    this.appearanceGeneration += 1;
    this.releasePromise = this.releaseAttachment(this.attachment);
  }

  private releaseAttachment(expected?: ComponentAttachment): Promise<void> {
    if (expected !== undefined && this.attachment !== expected) {
      return this.releasePromise;
    }
    const attachment = expected ?? this.attachment;
    this.attachment = undefined;
    if (attachment === undefined) {
      this.nodeController.disposeRoot();
      return Promise.resolve();
    }
    // RootNode owns the ContentSlot handle and must be dropped synchronously while this component
    // still owns a live NodeContent. Host/plugin cleanup may continue asynchronously afterwards.
    attachment.nativeModule.disposeRender?.(attachment.renderOwner);
    return BridgeHostRegistry.detachWindow(
      attachment.sessionId,
      attachment.moduleName,
      attachment.windowKey,
    )
      .catch(() => {})
      .finally(() => {
        this.nodeController.disposeRoot();
      });
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
