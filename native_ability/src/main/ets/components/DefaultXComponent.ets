import { NodeContent } from "@kit.ArkUI";
import { FrameNode, NodeController } from "@ohos.arkui.node";
import { UIContext } from "@ohos.arkui.UIContext";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { Module } from "../ability/type";
import { BridgeHostRegistry } from "../bridge/BridgeHost";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";
import { WindowManager } from "../window/WindowManager";

export const RouteName = "NativeAbility";

let nextRenderOwnerId: number = 1;

/**
 * Hook invoked once the primary webview controller has attached. WebviewPlugin.
 * handleControllerAttached calls `notifyPrimaryWebviewController` after the controller is
 * attached and verified, injecting it into PredefinedActionExecutor so that Tray
 * right-click predefined actions (Copy/Cut/Paste/SelectAll/Undo/Redo) can reach the
 * live webview controller instead of no-op'ing. The callback itself is registered by
 * NativeAbility.setupMenuPopup via `setPrimaryWebviewControllerCallback`.
 */
let primaryWebviewControllerCallback: ((controller: ESObject) => void) | null = null;
export function setPrimaryWebviewControllerCallback(cb: (controller: ESObject) => void): void {
  primaryWebviewControllerCallback = cb;
}
export function clearPrimaryWebviewControllerCallback(): void {
  primaryWebviewControllerCallback = null;
}

/**
 * Invoker for `primaryWebviewControllerCallback`. Called by WebviewPlugin.
 * handleControllerAttached to forward the freshly-attached webview controller to
 * NativeAbility's PredefinedActionExecutor. Kept as a same-module wrapper rather than
 * exporting the `let` directly: cross-module live-binding of a `let` is unreliable,
 * whereas an exported function closes over the module-local binding stably.
 */
export function notifyPrimaryWebviewController(controller: ESObject): void {
  if (primaryWebviewControllerCallback) {
    primaryWebviewControllerCallback(controller);
    // one-shot: clear after injecting so only the first-attached webview (=main)
    // controller is captured. Without this, every sub-window attach overwrites
    // executor.controller, so Tray Copy/Cut run getSelection() on the wrong window.
    // Mirrors origin/ohdev ArkHelper.ets:411 (lost during bridge refactor).
    clearPrimaryWebviewControllerCallback();
  }
}

interface ComponentAttachment {
  sessionId: string;
  moduleName: string;
  renderOwner: string;
  nativeModule: Module;
  nativeSubWindow: boolean;
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
  // Main window mode: moduleName is non-empty
  @Prop moduleName: string = "";
  // Sub-window mode: windowId is non-zero
  @Prop windowId: number = 0;

  private rootSlot = new NodeContent();
  private nodeController = new BridgeRootNodeController();
  @StorageProp("bridgeSessionId") bridgeSessionId: string = "";
  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";
  @State private blurRadius: number = 0;
  private appearanceGeneration: number = 0;
  private attachment?: ComponentAttachment;
  private releasePromise: Promise<void> = Promise.resolve();
  private releaseSurfaceBlur?: () => void;

  async aboutToAppear(): Promise<void> {
    const generation = ++this.appearanceGeneration;
    await this.releasePromise;
    if (generation !== this.appearanceGeneration) {
      return;
    }
    const moduleName = this.moduleName.trim();
    hilog.info(
      0xa01999,
      "DefaultXComponent",
      'aboutToAppear: moduleName="%{public}s" windowId=%{public}d',
      moduleName,
      this.windowId,
    );

    // Sub-window mode: no moduleName, but windowId > 0.
    // Create a root FrameNode for webviews to mount into, register with WindowManager.
    // No bridge host / NativeModule needed — the webview plugin handles rendering.
    if (!moduleName && this.windowId > 0) {
      const root = this.nodeController.makeNode(this.getUIContext());
      WindowManager.getInstance().registerComponentRoot(this.windowId, root);
      hilog.info(
        0xa01999,
        "DefaultXComponent",
        "sub-window mode: root registered for windowId=%{public}d",
        this.windowId,
      );
      return;
    }

    if (moduleName && this.windowId > 0) {
      const nativeModule = await NativeModuleLoader.load(moduleName, this.loadMode);
      if (generation !== this.appearanceGeneration) {
        return;
      }
      if (!nativeModule.renderWindow) {
        throw new Error(`Native module '${moduleName}' does not support sub-window rendering`);
      }
      const renderOwner = `${this.bridgeSessionId}:${moduleName}:${nextRenderOwnerId++}`;
      nativeModule.renderWindow(this.rootSlot, renderOwner, this.windowId);
      if (generation !== this.appearanceGeneration) {
        nativeModule.disposeRender(renderOwner);
        return;
      }
      this.attachment = {
        sessionId: this.bridgeSessionId,
        moduleName,
        renderOwner,
        nativeModule,
        nativeSubWindow: true,
      };
      this.attachSurfaceBlur(generation);
      return;
    }

    if (!moduleName) {
      throw new Error("DefaultXComponent.moduleName is required");
    }

    const nativeModule = await NativeModuleLoader.load(moduleName, this.loadMode);
    if (generation !== this.appearanceGeneration) {
      return;
    }

    // Apply transparent background + container color for main windows that were
    // created with transparent=true. This was dead code after the pluginize refactor
    // (the old aboutToAppear called it, but the new one didn't). Without this,
    // backdrop blur on transparent windows has no visible effect because
    // the container remains opaque.
    hilog.debug(
      0xa01999,
      "DefaultXComponent",
      "aboutToAppear: calling applyTransparentBackground(windowId=%{public}d)",
      this.windowId,
    );
    WindowManager.getInstance().applyTransparentBackground(this.windowId);

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
      nativeSubWindow: false,
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
        return;
      }
      this.attachSurfaceBlur(generation);
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
    this.releaseSurfaceBlur?.();
    this.releaseSurfaceBlur = undefined;
    // Sub-window mode cleanup: unregister component root and dispose FrameNode
    if (!this.moduleName.trim() && this.windowId > 0) {
      WindowManager.getInstance().unregisterComponentRoot(this.windowId);
      this.nodeController.disposeRoot();
      return;
    }
    this.releasePromise = this.releaseAttachment(this.attachment);
  }

  private releaseAttachment(expected?: ComponentAttachment): Promise<void> {
    if (expected !== undefined && this.attachment !== expected) {
      return this.releasePromise;
    }
    this.releaseSurfaceBlur?.();
    this.releaseSurfaceBlur = undefined;
    const attachment = expected ?? this.attachment;
    this.attachment = undefined;
    if (attachment === undefined) {
      this.nodeController.disposeRoot();
      return Promise.resolve();
    }
    // RootNode owns the ContentSlot handle and must be dropped synchronously while this component
    // still owns a live NodeContent. Host/plugin cleanup may continue asynchronously afterwards.
    attachment.nativeModule.disposeRender(attachment.renderOwner);
    if (attachment.nativeSubWindow) {
      this.nodeController.disposeRoot();
      return Promise.resolve();
    }
    return BridgeHostRegistry.detachComponent(
      attachment.sessionId,
      attachment.moduleName,
      attachment.renderOwner,
    )
      .catch(() => {})
      .finally(() => {
        this.nodeController.disposeRoot();
      });
  }

  private attachSurfaceBlur(generation: number): void {
    if (generation !== this.appearanceGeneration) {
      return;
    }
    const manager = WindowManager.getInstance();
    this.blurRadius = manager.getPendingBlur(this.windowId);
    this.releaseSurfaceBlur?.();
    this.releaseSurfaceBlur = manager.registerSurfaceBlurCallback(
      this.windowId,
      (radius: number): void => {
        if (generation === this.appearanceGeneration) {
          this.blurRadius = radius;
        }
      },
    );
  }

  build() {
    Stack() {
      // Blur the pixels behind this window before the transparent GPUI surface is composed.
      Row()
        .width("100%")
        .height("100%")
        .hitTestBehavior(HitTestMode.None)
        .backgroundColor(Color.Transparent)
        .backdropBlur(this.blurRadius)
      // ContentSlot is the GPUI input surface. These full-window layout nodes must not take
      // touches from it. Interactive plugin content blocks the lower layer at its own bounds.
      ContentSlot(this.rootSlot)
      Row() {
        Column() {
          NodeContainer(this.nodeController)
            .height("100%")
            .width("100%")
            .hitTestBehavior(HitTestMode.None)
        }
        .width("100%")
        .hitTestBehavior(HitTestMode.None)
        .backgroundColor(Color.Transparent)
      }
      .height("100%")
      .hitTestBehavior(HitTestMode.None)
      .backgroundColor(Color.Transparent)
    }.backgroundColor(Color.Transparent);
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
    } catch {}
  }
}
