import { UIContext } from "@ohos.arkui.UIContext";
import { FrameNode, NodeController } from "@ohos.arkui.node";

export const DEFAULT_PLUGIN_NODE_SLOT = "xcomponent-overlay";

type NodeCleanup = () => void;

interface MountedNode {
  node: FrameNode;
  cleanup?: NodeCleanup;
}

interface SlotWaiter {
  resolve: (slot: BridgeNodeSlot) => void;
  reject: (reason: Error) => void;
}

/**
 * Owns one ArkUI FrameNode root. Plugins mount child FrameNodes here; the core never needs to
 * know whether the child is a WebView, a native node, a BuilderNode, or another plugin surface.
 */
export class BridgeNodeSlotController extends NodeController {
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

  rootNode(): FrameNode {
    return this.makeNode(this.uiContext);
  }

  disposeRoot(): void {
    this.root?.dispose();
    this.root = null;
  }
}

/** A module/session-scoped slot that a plugin can use to mount arbitrary ArkUI FrameNodes. */
export class BridgeNodeSlot {
  private readonly mountedNodes: Map<string, MountedNode> = new Map();
  private disposed = false;
  readonly sessionId: string;
  readonly moduleName: string;
  readonly slotId: string;
  readonly uiContext: UIContext;
  private readonly controller: BridgeNodeSlotController;

  constructor(
    sessionId: string,
    moduleName: string,
    slotId: string,
    uiContext: UIContext,
    controller: BridgeNodeSlotController,
  ) {
    this.sessionId = sessionId;
    this.moduleName = moduleName;
    this.slotId = slotId;
    this.uiContext = uiContext;
    this.controller = controller;
  }

  mount(key: string, node: FrameNode, cleanup?: NodeCleanup): void {
    this.assertActive();
    if (!key || !/^[A-Za-z0-9._-]+$/.test(key)) {
      throw new Error("Bridge node mount key must contain only letters, digits, '.', '_' or '-'");
    }
    this.unmount(key);
    try {
      this.controller.rootNode().appendChild(node);
    } catch (error) {
      throw new Error(`Unable to mount bridge node '${key}': ${String(error)}`);
    }
    this.mountedNodes.set(key, { node, cleanup });
  }

  unmount(key: string): void {
    const mounted = this.mountedNodes.get(key);
    if (!mounted) {
      return;
    }
    this.mountedNodes.delete(key);
    try {
      this.controller.rootNode().removeChild(mounted.node);
    } catch {}
    try {
      mounted.cleanup?.();
    } catch {}
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    const keys = Array.from(this.mountedNodes.keys());
    for (const key of keys) {
      this.unmount(key);
    }
    this.controller.disposeRoot();
  }

  isActive(): boolean {
    return !this.disposed;
  }

  private assertActive(): void {
    if (this.disposed) {
      throw new Error(`Bridge node slot '${this.slotId}' is no longer mounted`);
    }
  }
}

function slotKey(sessionId: string, moduleName: string, slotId: string): string {
  return `${sessionId}:${moduleName}:${slotId}`;
}

/**
 * ArkTS-only rendezvous point between a plugin factory and an explicitly placed node host.
 * Context objects and FrameNodes do not cross the N-API boundary.
 */
export class BridgeNodeSlotRegistry {
  private static readonly slots: Map<string, BridgeNodeSlot> = new Map();
  private static readonly waiters: Map<string, SlotWaiter[]> = new Map();

  static attach(
    sessionId: string,
    moduleName: string,
    slotId: string,
    uiContext: UIContext,
    controller: BridgeNodeSlotController,
  ): BridgeNodeSlot {
    if (!slotId || !/^[A-Za-z0-9._-]+$/.test(slotId)) {
      throw new Error("Bridge node slotId must contain only letters, digits, '.', '_' or '-'");
    }
    const key = slotKey(sessionId, moduleName, slotId);
    const existing = BridgeNodeSlotRegistry.slots.get(key);
    if (existing?.isActive()) {
      throw new Error(`Bridge node slot '${slotId}' is already mounted for ${moduleName}`);
    }
    if (existing !== undefined) {
      BridgeNodeSlotRegistry.slots.delete(key);
    }
    const slot = new BridgeNodeSlot(sessionId, moduleName, slotId, uiContext, controller);
    BridgeNodeSlotRegistry.slots.set(key, slot);
    const waiters = BridgeNodeSlotRegistry.waiters.get(key);
    if (waiters !== undefined) {
      BridgeNodeSlotRegistry.waiters.delete(key);
      for (const waiter of waiters) {
        waiter.resolve(slot);
      }
    }
    return slot;
  }

  static require(sessionId: string, moduleName: string, slotId: string): BridgeNodeSlot {
    const key = slotKey(sessionId, moduleName, slotId);
    const slot = BridgeNodeSlotRegistry.slots.get(key);
    if (!slot?.isActive()) {
      if (slot !== undefined) {
        BridgeNodeSlotRegistry.slots.delete(key);
      }
      throw new Error(
        `Bridge node slot '${slotId}' is not mounted for ${moduleName}; place DefaultXComponent or BridgeNodeHost before invoking this plugin`,
      );
    }
    return slot;
  }

  /**
   * Waits for a business-owned named node layer to mount. This is a lifecycle rendezvous: attach
   * resolves it, and the caller's cancellation signal rejects it. It intentionally has no
   * readiness timer because page composition time is not an error condition. Async plugins use
   * this instead of failing when a page is still composing its BridgeNodeHost; sync plugins must
   * keep using `require`, because they cannot suspend a main-thread platform callback.
   */
  static async waitFor(
    sessionId: string,
    moduleName: string,
    slotId: string,
    onCancel: (listener: () => void) => () => void,
  ): Promise<BridgeNodeSlot> {
    if (!slotId || !/^[A-Za-z0-9._-]+$/.test(slotId)) {
      throw new Error("Bridge node slotId must contain only letters, digits, '.', '_' or '-'");
    }
    const key = slotKey(sessionId, moduleName, slotId);
    const current = BridgeNodeSlotRegistry.slots.get(key);
    if (current?.isActive()) {
      return current;
    }
    if (current !== undefined) {
      BridgeNodeSlotRegistry.slots.delete(key);
    }
    return await new Promise<BridgeNodeSlot>((resolve, reject) => {
      let settled = false;
      let unsubscribe: () => void = (): void => {};
      const waiter: SlotWaiter = {
        resolve: (slot: BridgeNodeSlot): void => {
          if (settled) {
            return;
          }
          settled = true;
          unsubscribe();
          resolve(slot);
        },
        reject: (reason: Error): void => {
          if (settled) {
            return;
          }
          settled = true;
          unsubscribe();
          reject(reason);
        },
      };
      const cancel = (): void => {
        BridgeNodeSlotRegistry.removeWaiter(key, waiter);
        waiter.reject(
          new Error(`Bridge node slot '${slotId}' wait was cancelled for ${moduleName}`),
        );
      };
      const waiters = BridgeNodeSlotRegistry.waiters.get(key) ?? [];
      waiters.push(waiter);
      BridgeNodeSlotRegistry.waiters.set(key, waiters);
      // `onCancel` may invoke `cancel` synchronously when the call was already cancelled. The
      // waiter is registered first so that path can remove it without leaving a stale entry.
      unsubscribe = onCancel(cancel);
    });
  }

  static detach(slot: BridgeNodeSlot): void {
    const key = slotKey(slot.sessionId, slot.moduleName, slot.slotId);
    if (BridgeNodeSlotRegistry.slots.get(key) !== slot) {
      return;
    }
    BridgeNodeSlotRegistry.slots.delete(key);
    slot.dispose();
  }

  private static removeWaiter(key: string, waiter: SlotWaiter): void {
    const waiters = BridgeNodeSlotRegistry.waiters.get(key);
    if (waiters === undefined) {
      return;
    }
    const index = waiters.indexOf(waiter);
    if (index >= 0) {
      waiters.splice(index, 1);
    }
    if (waiters.length === 0) {
      BridgeNodeSlotRegistry.waiters.delete(key);
    }
  }
}

/**
 * A business-placeable host for a named plugin node layer. `underlay` and `foreground` keep layout
 * ownership in the business page while plugins receive only the neutral FrameNode mount point.
 */
@Component
export struct BridgeNodeHost {
  moduleName: string = "";
  slotId: string = "plugin-content";
  @StorageProp("bridgeSessionId") bridgeSessionId: string = "";
  private controller = new BridgeNodeSlotController(this.getUIContext());
  private slot?: BridgeNodeSlot;

  @Builder
  private empty(): void {}

  @BuilderParam underlay: () => void = this.empty;
  @BuilderParam foreground: () => void = this.empty;

  aboutToAppear(): void {
    const moduleName = this.moduleName.trim();
    if (!moduleName || !this.bridgeSessionId) {
      throw new Error("BridgeNodeHost requires moduleName and an active bridgeSessionId");
    }
    this.slot = BridgeNodeSlotRegistry.attach(
      this.bridgeSessionId,
      moduleName,
      this.slotId,
      this.getUIContext(),
      this.controller,
    );
  }

  aboutToDisappear(): void {
    if (this.slot) {
      BridgeNodeSlotRegistry.detach(this.slot);
      this.slot = undefined;
    }
  }

  build() {
    Stack() {
      this.underlay()
      NodeContainer(this.controller)
        .width("100%")
        .height("100%")
      this.foreground()
    }
    .width("100%")
    .height("100%");
  }
}
