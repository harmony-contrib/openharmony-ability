import { NodeContent } from "@kit.ArkUI";
import { FrameNode, NodeController } from "@ohos.arkui.node";
import { UIContext } from "@ohos.arkui.UIContext";
import { Module } from "../ability/type";
import { BridgeHostRegistry } from "../bridge/BridgeHost";
import { Log } from "../runtime/Log";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";

let nextRenderOwnerId: number = 1;

interface ComponentAttachment {
  sessionId: string;
  moduleName: string;
  renderOwner: string;
  nativeModule: Module;
}

/**
 * Mounts only the Rust XComponent render surface and module root. The generic bridge transport
 * already belongs to the NativeAbility/module session, so ability-only capabilities do not wait
 * for this component. A capability that needs ArkUI content (for example WebView) owns a plugin
 * and mounts its own FrameNode into the root this component provides.
 *
 * Every instance must use its own native module. One Ability may host multiple instances (in the
 * same window or different windows) by declaring and assigning a distinct module to each one.
 */
@Component
export struct DefaultXComponent {
  moduleName: string = "";
  private rootSlot = new NodeContent();
  private nodeController = new BridgeRootNodeController();
  @StorageProp("bridgeSessionId") bridgeSessionId: string = "";
  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";
  private appearanceGeneration: number = 0;
  private attachment?: ComponentAttachment;
  private releasePromise: Promise<void> = Promise.resolve();

  aboutToAppear(): void {
    // ArkUI never awaits lifecycle callbacks: keep the callback synchronous and run the actual
    // attachment as a supervised task so a failure surfaces in hilog instead of becoming an
    // unhandled Promise rejection.
    const generation = ++this.appearanceGeneration;
    void this.attachForAppearance(generation).catch((error: Error) => {
      Log.error(
        `[DefaultXComponent] failed to attach native module '${this.moduleName}': ${String(error)}`,
      );
    });
  }

  private async attachForAppearance(generation: number): Promise<void> {
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
    // NativeAbility owns the module/session sinks from ability-create onward. The component only
    // supplies the render surface and UI root; ability-only plugins never depend on appearance.
    const renderOwner = `${sessionId}:${moduleName}:${nextRenderOwnerId++}`;
    nativeModule.render(this.rootSlot, renderOwner);

    if (generation !== this.appearanceGeneration) {
      nativeModule.disposeRender(renderOwner);
      return;
    }

    const attachment: ComponentAttachment = {
      sessionId,
      moduleName,
      renderOwner,
      nativeModule,
    };
    this.attachment = attachment;
    try {
      // Create this module's root eagerly (NodeContainer asks the controller lazily) so it exists
      // before `ui-context-ready`. Keep it inside the render transaction: FrameNode construction
      // failure must release the native RootNode/render owner as well.
      const root = this.nodeController.makeNode(this.getUIContext());
      await BridgeHostRegistry.attachComponent(
        sessionId,
        moduleName,
        renderOwner,
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
    attachment.nativeModule.disposeRender(attachment.renderOwner);
    return BridgeHostRegistry.detachComponent(
      attachment.sessionId,
      attachment.moduleName,
      attachment.renderOwner,
    )
      .catch((error: Error) => {
        Log.error(
          `[DefaultXComponent] failed to detach native module '${attachment.moduleName}': ${String(error)}`,
        );
      })
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
 * Owns this native module's single component root FrameNode. Plugins never touch this controller directly; they
 * receive the root through `BridgePluginContext.getRootFrameNode()`.
 */
class BridgeRootNodeController extends NodeController {
  private root: FrameNode | null = null;

  makeNode(uiContext: UIContext): FrameNode {
    if (this.root === null) {
      this.root = new FrameNode(uiContext);
    }
    return this.root;
  }

  disposeRoot(): void {
    const root = this.root;
    this.root = null;
    try {
      root?.dispose();
    } catch (error) {
      Log.warn(`[DefaultXComponent] root FrameNode dispose failed: ${String(error)}`);
    }
  }
}
