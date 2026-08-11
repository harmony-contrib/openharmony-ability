import common from "@ohos.app.ability.common";
import { FrameNode } from "@ohos.arkui.node";
import { UIContext } from "@ohos.arkui.UIContext";
import window from "@ohos.window";
import {
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeEmptyLifecyclePayload,
  BridgeLifecycleEvent,
  BridgeTypedValue,
  AsyncBridgePlugin,
  MainThreadSyncBridgePlugin,
  BridgePlugin,
  BridgePluginContext,
  BridgePluginFactory,
  BridgePluginHookContext,
  BridgeWindowLifecyclePayload,
  BridgeWindowScope,
} from "../ability/type";
import { SerialTaskQueue } from "../runtime/SerialTaskQueue";
import { CancellableTaskScope, TaskCancellationSignal } from "../runtime/CancellableTaskScope";

const MAX_TIMEOUT_MS = 60_000;
const MAX_PAYLOAD_BYTES = 512 * 1024;
const MAX_LIFECYCLE_HISTORY = 16;
const PLUGIN_HOOK_TIMEOUT_MS = 5_000;
const PLUGIN_HOOK_TIMEOUT_PREFIX = "bridge-plugin-hook-timeout:";

type BridgeMainThreadEventSink = (
  pluginId: string,
  event: string,
  requestTypeName: string,
  responseTypeName: string,
  value: ESObject,
) => ESObject;

type BridgeLifecycleSink = (kind: string) => void;

interface HostedPlugin {
  plugin: BridgePlugin;
  installed: boolean;
  installAttempted: boolean;
  installError?: string;
  hookError?: string;
  installing?: Promise<void>;
}

interface MountedChild {
  node: FrameNode;
  cleanup?: () => void;
}

/**
 * Per-window node surface state. Every `DefaultXComponent` instance (one per window) attaches its
 * own root FrameNode, so sub-window plugin trees never overwrite the main window's.
 */
interface HostWindowState {
  uiContext?: UIContext;
  rootFrameNode?: FrameNode;
  mountedChildren: Map<string, MountedChild>;
  nodeHandles: Map<number, FrameNode>;
  nodeParents: Map<number, FrameNode>;
  nextNodeHandle: number;
}

const NODE_SURFACE_PLUGIN_ID = "ohos.node";
export const MAIN_WINDOW_KEY = "main";

/**
 * Built-in session-surface plugin. It is installed by every BridgeHost before business plugins
 * and exposes opaque FrameNode handles to Rust (`create-container` / `append-child` /
 * `mount-into-root` / `dispose`), so an RS-layer node tree can be composed and mounted without
 * FrameNode values crossing the N-API boundary.
 */
class NodeSurfacePlugin implements AsyncBridgePlugin {
  readonly id = NODE_SURFACE_PLUGIN_ID;
  readonly version = 1;
  readonly requires: BridgeContextRequirement[] = ["ui-context"];
  readonly execution: "async" = "async";
  private readonly host: BridgeHost;

  constructor(host: BridgeHost) {
    this.host = host;
  }

  async invokeAsync(
    action: string,
    request: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (action === "create-container") {
      const payload = this.expectRequest<NodeCreateContainerPayload>(
        request,
        "ohos.node.CreateContainerRequest",
        action,
      );
      return {
        typeName: "ohos.node.HandleResponse",
        value: new NodeHandleResponse(
          this.host.createContainerNode(payload.windowKey ?? MAIN_WINDOW_KEY),
        ),
      };
    }
    if (action === "append-child") {
      const payload = this.expectRequest<NodeAppendChildPayload>(
        request,
        "ohos.node.AppendChildRequest",
        action,
      );
      this.host.appendChildByHandle(
        payload.windowKey ?? MAIN_WINDOW_KEY,
        payload.parentHandle,
        payload.childHandle,
      );
      return {
        typeName: "ohos.node.Acknowledgement",
        value: new NodeAcknowledgement(true),
      };
    }
    if (action === "mount-into-root") {
      const payload = this.expectRequest<NodeMountIntoRootPayload>(
        request,
        "ohos.node.MountIntoRootRequest",
        action,
      );
      this.host.mountIntoRoot(payload.windowKey ?? MAIN_WINDOW_KEY, payload.handle);
      return {
        typeName: "ohos.node.Acknowledgement",
        value: new NodeAcknowledgement(true),
      };
    }
    if (action === "dispose") {
      const payload = this.expectRequest<NodeDisposePayload>(
        request,
        "ohos.node.DisposeRequest",
        action,
      );
      this.host.disposeNode(payload.windowKey ?? MAIN_WINDOW_KEY, payload.handle);
      return {
        typeName: "ohos.node.Acknowledgement",
        value: new NodeAcknowledgement(true),
      };
    }
    throw new Error(`Unsupported ohos.node action '${action}'`);
  }

  private expectRequest<T>(request: BridgeTypedValue, typeName: string, action: string): T {
    if (
      request.typeName !== typeName ||
      request.value === null ||
      typeof request.value !== "object"
    ) {
      throw new Error(`ohos.node.${action} requires bridge type ${typeName}`);
    }
    return request.value as T;
  }
}

interface NodeCreateContainerPayload {
  windowKey?: string | null;
}

interface NodeAppendChildPayload {
  parentHandle: number;
  childHandle: number;
  windowKey?: string | null;
}

interface NodeMountIntoRootPayload {
  handle: number;
  windowKey?: string | null;
}

interface NodeDisposePayload {
  handle: number;
  windowKey?: string | null;
}

class NodeHandleResponse {
  readonly handle: number;

  constructor(handle: number) {
    this.handle = handle;
  }
}

class NodeAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

interface BridgeCallState {
  pluginId: string;
  cancelled: boolean;
  cancelListeners: Array<() => void>;
  rejectCancellation?: (reason: Error) => void;
}

interface ActivePluginHook {
  label: string;
  scope: CancellableTaskScope;
}

interface PendingWindowAttachment {
  state: HostWindowState;
  cancelled: boolean;
}

function isBridgeIdentifier(value: string): boolean {
  return value.length > 0 && /^[A-Za-z0-9._-]+$/.test(value);
}

function clampTimeout(timeoutMs: number): number {
  if (!Number.isFinite(timeoutMs)) {
    return MAX_TIMEOUT_MS;
  }
  return Math.max(1, Math.min(Math.floor(timeoutMs), MAX_TIMEOUT_MS));
}

function normalizedRequirements(requires?: BridgeContextRequirement[]): BridgeContextRequirement[] {
  return requires ? requires.slice() : [];
}

/**
 * One module-scoped host. It owns context readiness, lifecycle replay, timeout/cancellation and
 * the direct ArkTS-to-Rust N-API event port; concrete capability implementations are supplied
 * as factories.
 */
class BridgeHost {
  private readonly plugins: Map<string, HostedPlugin> = new Map();
  private readonly contextWaiters: Array<() => void> = [];
  private readonly lifecycleHistory: BridgeLifecycleEvent[] = [];
  // A small list is intentional here: ArkTS compatibility is better than depending on a
  // collection implementation for a handful of in-flight bridge calls.
  private readonly activeCalls: BridgeCallState[] = [];
  private readonly activeHooks: ActivePluginHook[] = [];
  private mainThreadEventSink?: BridgeMainThreadEventSink;
  private lifecycleSink?: BridgeLifecycleSink;
  private eventSinkToken: number = 0;
  private windowStage?: window.WindowStage;
  private windowStageGeneration: number = 0;
  private windowStageClearPromise?: Promise<void>;
  private abilityReady: boolean = false;
  private windowStageReady: boolean = false;
  private uiContextReady: boolean = false;
  private closing: boolean = false;
  private disposed: boolean = false;
  private disposePromise?: Promise<void>;
  private readonly lifecycleQueue = new SerialTaskQueue((label: string, error: Error): void => {
    console.error(
      `[BridgeHost:${this.moduleName}] lifecycle operation '${label}' failed: ${String(error)}`,
    );
  });
  private readonly sessionId: string;
  private readonly moduleName: string;
  private readonly abilityContext: common.UIAbilityContext;
  // Per-window node surfaces: every `DefaultXComponent` instance (one per window) registers its
  // own root FrameNode under its `windowKey` (`"main"` by default), so sub-window plugin trees
  // never overwrite the main window's. Each window owns its keyed mounts and the opaque handle
  // table of the built-in ohos.node plugin.
  private readonly windows: Map<string, HostWindowState> = new Map();
  private readonly pendingWindows: Map<string, PendingWindowAttachment> = new Map();

  constructor(sessionId: string, moduleName: string, abilityContext: common.UIAbilityContext) {
    this.sessionId = sessionId;
    this.moduleName = moduleName;
    this.abilityContext = abilityContext;
  }

  /** Registers plugin instances without activating hooks. NativeAbility attaches Rust sinks first. */
  registerFactories(factories: BridgePluginFactory[]): void {
    this.installNodeSurfacePlugin();
    for (const factory of factories) {
      const modules = factory.modules;
      if (modules && modules.length > 0 && modules.indexOf(this.moduleName) < 0) {
        continue;
      }
      this.validateFactory(factory);

      // Identity lives on the instance: create, validate, then inject the
      // session-scoped context before any lifecycle hook can run.
      const plugin = factory.create();
      this.validatePlugin(plugin);
      if (this.plugins.has(plugin.id)) {
        throw new Error(`Duplicate bridge plugin '${plugin.id}' in module ${this.moduleName}`);
      }
      plugin.attachContext?.(this.pluginContext(plugin.id));
      this.plugins.set(plugin.id, {
        plugin,
        installed: false,
        installAttempted: false,
      });
    }
  }

  /**
   * Installs the built-in `ohos.node` surface plugin ahead of business plugins. It closes over
   * this host so its actions operate on the session root and handle table directly.
   */
  private installNodeSurfacePlugin(): void {
    const plugin = new NodeSurfacePlugin(this);
    this.plugins.set(plugin.id, {
      plugin,
      installed: false,
      installAttempted: false,
    });
  }

  /**
   * Registers one window's node surface. `DefaultXComponent` calls this from `aboutToAppear`
   * after creating its root. Attaching the `"main"` window emits `ui-context-ready` (and wakes
   * context waiters); sub-window attachments only register state.
   */
  attachWindow(windowKey: string, uiContext: UIContext, root: FrameNode): Promise<void> {
    this.assertActive();
    this.assertWindowKey(windowKey);
    if (this.windows.has(windowKey) || this.pendingWindows.has(windowKey)) {
      throw new Error(
        `Bridge window '${windowKey}' is already attached for '${this.moduleName}'; each DefaultXComponent needs a unique windowKey`,
      );
    }
    const pending: PendingWindowAttachment = {
      state: {
        uiContext,
        rootFrameNode: root,
        mountedChildren: new Map(),
        nodeHandles: new Map(),
        nodeParents: new Map(),
        nextNodeHandle: 1,
      },
      cancelled: false,
    };
    this.pendingWindows.set(windowKey, pending);

    return this.enqueueLifecycle(`attach window '${windowKey}'`, async (): Promise<void> => {
      this.pendingWindows.delete(windowKey);
      if (pending.cancelled) {
        return;
      }
      this.assertActive();
      if (!this.windowStageReady) {
        throw new Error(
          `Bridge window '${windowKey}' cannot attach without an active WindowStage for '${this.moduleName}'`,
        );
      }
      this.windows.set(windowKey, pending.state);
      await this.deliverLifecycle({
        kind: "window-attached",
        payload: new BridgeWindowLifecyclePayload(windowKey),
      });
      if (windowKey !== MAIN_WINDOW_KEY) {
        return;
      }

      this.uiContextReady = true;
      this.notifyContextChanged();
      // Rust readiness must be visible before an ArkTS plugin's onInstall can synchronously emit
      // a typed platform event back into Rust.
      this.notifyRustLifecycle("ui-context-ready");
      await this.deliverLifecycle({
        kind: "ui-context-ready",
        payload: new BridgeEmptyLifecyclePayload(),
      });
    });
  }

  /**
   * Unregisters one window's node surface, unmounting its keyed children and disposing its
   * handle-owned nodes. The root FrameNode itself is disposed by its owner
   * (`DefaultXComponent`). Detaching the `"main"` window emits `ui-context-destroy`.
   */
  async detachWindow(windowKey: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    const pending = this.pendingWindows.get(windowKey);
    if (pending !== undefined) {
      pending.cancelled = true;
      this.pendingWindows.delete(windowKey);
      await this.enqueueLifecycle(`cancel window attachment '${windowKey}'`, async () => {});
      return;
    }
    const state = this.windows.get(windowKey);
    if (state === undefined) {
      const windowStageClearPromise = this.windowStageClearPromise;
      if (windowStageClearPromise !== undefined) {
        await windowStageClearPromise;
      }
      return;
    }
    this.windows.delete(windowKey);
    if (windowKey === MAIN_WINDOW_KEY) {
      // Make new calls fail immediately. The queued lifecycle hook still owns the old state and
      // releases it before a later attachment can become ready.
      this.uiContextReady = false;
      this.cancelCallsWithMissingContext();
      this.notifyContextChanged();
    }

    await this.enqueueLifecycle(`detach window '${windowKey}'`, async (): Promise<void> => {
      await this.deliverLifecycle({
        kind: "window-detached",
        payload: new BridgeWindowLifecyclePayload(windowKey),
      });
      if (windowKey === MAIN_WINDOW_KEY) {
        await this.deliverLifecycle({
          kind: "ui-context-destroy",
          payload: new BridgeEmptyLifecyclePayload(),
        });
      }
      this.disposeWindowState(state);
      if (windowKey === MAIN_WINDOW_KEY) {
        this.notifyRustLifecycle("ui-context-destroy");
      }
    });
  }

  /** Creates an empty container FrameNode in `windowKey` and returns its opaque handle (ohos.node). */
  createContainerNode(windowKey: string): number {
    const state = this.requireWindow(windowKey);
    const node = new FrameNode(this.requireUiContext(state));
    const handle = state.nextNodeHandle++;
    state.nodeHandles.set(handle, node);
    return handle;
  }

  /** Appends the node of `childHandle` under the node of `parentHandle` (ohos.node). */
  appendChildByHandle(windowKey: string, parentHandle: number, childHandle: number): void {
    const state = this.requireWindow(windowKey);
    const parent = this.lookupNodeHandle(state, parentHandle, "append-child parent");
    const child = this.lookupNodeHandle(state, childHandle, "append-child child");
    this.appendFrameNode(parent, child, `append child handle '${childHandle}'`);
    state.nodeParents.set(childHandle, parent);
  }

  /** Appends a handle-owned node to the `windowKey` root (ohos.node). */
  mountIntoRoot(windowKey: string, handle: number): void {
    const state = this.requireWindow(windowKey);
    const node = this.lookupNodeHandle(state, handle, "mount-into-root");
    const root = this.requireRootFrameNode(state);
    this.appendFrameNode(root, node, `mount handle '${handle}' into '${windowKey}'`);
    state.nodeParents.set(handle, root);
  }

  private appendFrameNode(parent: FrameNode, child: FrameNode, operation: string): void {
    try {
      parent.appendChild(child);
    } catch (error) {
      throw new Error(`Unable to ${operation}: ${String(error)}`);
    }
  }

  /** Disposes a handle-owned node: detaches it from its recorded parent and frees the handle. */
  disposeNode(windowKey: string, handle: number): void {
    const state = this.windows.get(windowKey);
    if (state === undefined) {
      return;
    }
    const node = state.nodeHandles.get(handle);
    if (!node) {
      return;
    }
    state.nodeHandles.delete(handle);
    const parent = state.nodeParents.get(handle);
    state.nodeParents.delete(handle);
    if (parent !== undefined) {
      try {
        parent.removeChild(node);
      } catch {}
    }
    try {
      node.dispose();
    } catch {}
  }

  private lookupNodeHandle(state: HostWindowState, handle: number, role: string): FrameNode {
    const node = state.nodeHandles.get(handle);
    if (!node) {
      throw new Error(`Unknown ohos.node handle '${handle}' for ${role}`);
    }
    return node;
  }

  private requireRootFrameNode(state: HostWindowState): FrameNode {
    const root = state.rootFrameNode;
    if (root === undefined) {
      throw new Error(`Bridge root FrameNode is not attached for '${this.moduleName}'`);
    }
    return root;
  }

  private requireUiContext(state: HostWindowState): UIContext {
    const uiContext = state.uiContext;
    if (uiContext === undefined) {
      throw new Error(`Bridge session '${this.sessionId}' has no UIContext`);
    }
    return uiContext;
  }

  private requireWindow(windowKey: string): HostWindowState {
    this.assertWindowKey(windowKey);
    const state = this.windows.get(windowKey);
    if (state === undefined) {
      throw new Error(
        `Bridge window '${windowKey}' is not attached for '${this.moduleName}'; place DefaultXComponent with a matching windowKey before invoking this plugin`,
      );
    }
    return state;
  }

  /** Returns a window-scoped node surface used by `BridgePluginContext.windowScope`. */
  windowScope(windowKey: string): BridgeWindowScope {
    this.assertWindowKey(windowKey);
    return {
      windowKey,
      getUIContext: (): UIContext => this.requireUiContext(this.requireWindow(windowKey)),
      getRootFrameNode: (): FrameNode => this.requireRootFrameNode(this.requireWindow(windowKey)),
      appendChild: (key: string, node: FrameNode, cleanup?: () => void): void =>
        this.appendChild(windowKey, key, node, cleanup),
      removeChild: (key: string): void => this.removeChild(windowKey, key),
      getFrameNode: (handle: number): FrameNode =>
        this.lookupNodeHandle(this.requireWindow(windowKey), handle, "context"),
    };
  }

  /** Plugin-context mount: appends an arbitrary FrameNode under the `windowKey` root. */
  appendChild(windowKey: string, key: string, node: FrameNode, cleanup?: () => void): void {
    this.assertActive();
    if (!isBridgeIdentifier(key)) {
      throw new Error("Bridge node mount key must contain only letters, digits, '.', '_' or '-'");
    }
    this.removeChild(windowKey, key);
    const state = this.requireWindow(windowKey);
    this.appendFrameNode(
      this.requireRootFrameNode(state),
      node,
      `mount '${key}' into '${windowKey}'`,
    );
    state.mountedChildren.set(key, { node, cleanup });
  }

  /** Plugin-context unmount: removes the node mounted under `key` in `windowKey` and runs its cleanup. */
  removeChild(windowKey: string, key: string): void {
    const state = this.windows.get(windowKey);
    if (state === undefined) {
      return;
    }
    const mounted = state.mountedChildren.get(key);
    if (!mounted) {
      return;
    }
    state.mountedChildren.delete(key);
    try {
      state.rootFrameNode?.removeChild(mounted.node);
    } catch {}
    try {
      mounted.cleanup?.();
    } catch {}
  }

  private disposeWindowState(state: HostWindowState): void {
    const mountedKeys = Array.from(state.mountedChildren.keys());
    for (const key of mountedKeys) {
      const mounted = state.mountedChildren.get(key);
      if (mounted === undefined) {
        continue;
      }
      state.mountedChildren.delete(key);
      try {
        state.rootFrameNode?.removeChild(mounted.node);
      } catch {}
      try {
        mounted.cleanup?.();
      } catch {}
    }
    const handleNodes = Array.from(state.nodeHandles.values());
    for (const node of handleNodes) {
      try {
        node.dispose();
      } catch {}
    }
    state.nodeHandles.clear();
    state.nodeParents.clear();
  }

  private assertWindowKey(windowKey: string): void {
    if (!isBridgeIdentifier(windowKey)) {
      throw new Error("Bridge windowKey must contain only letters, digits, '.', '_' or '-'");
    }
  }

  /** Marks the Ability context ready only after the native module and both Rust sinks exist. */
  async activateAbility(event: BridgeLifecycleEvent): Promise<void> {
    this.assertActive();
    await this.enqueueLifecycle("ability-create", async (): Promise<void> => {
      this.assertActive();
      this.abilityReady = true;
      this.notifyContextChanged();
      await this.deliverLifecycle(event);
    });
  }

  async setWindowStage(windowStage: window.WindowStage): Promise<void> {
    this.assertActive();
    const generation = ++this.windowStageGeneration;
    await this.enqueueLifecycle("window-stage-create", async (): Promise<void> => {
      this.assertActive();
      if (generation !== this.windowStageGeneration) {
        return;
      }
      this.windowStage = windowStage;
      this.windowStageReady = true;
      this.notifyContextChanged();
    });
  }

  async clearWindowStage(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.invalidateWindowStage();
    const activeClear = this.windowStageClearPromise;
    if (activeClear !== undefined) {
      await activeClear;
      return;
    }
    const clearPromise = this.enqueueLifecycle("window-stage-destroy", async (): Promise<void> => {
      this.windowStageReady = false;
      // The WindowStage belongs to the Ability (main window). Detach every registered window
      // surface; only the main window emits `ui-context-destroy`.
      const windowEntries = Array.from(this.windows.entries());
      this.windows.clear();
      if (this.uiContextReady) {
        this.uiContextReady = false;
        this.cancelCallsWithMissingContext();
        this.notifyContextChanged();
      }
      for (const windowEntry of windowEntries) {
        const windowKey = windowEntry[0];
        const state = windowEntry[1];
        await this.deliverLifecycle({
          kind: "window-detached",
          payload: new BridgeWindowLifecyclePayload(windowKey),
        });
        if (windowKey === MAIN_WINDOW_KEY) {
          await this.deliverLifecycle({
            kind: "ui-context-destroy",
            payload: new BridgeEmptyLifecyclePayload(),
          });
        }
        this.disposeWindowState(state);
        if (windowKey === MAIN_WINDOW_KEY) {
          this.notifyRustLifecycle("ui-context-destroy");
        }
      }
      await this.deliverLifecycle({
        kind: "window-stage-destroy",
        payload: new BridgeEmptyLifecyclePayload(),
      });
      this.windowStage = undefined;
    });
    this.windowStageClearPromise = clearPromise;
    try {
      await clearPromise;
    } finally {
      if (this.windowStageClearPromise === clearPromise) {
        this.windowStageClearPromise = undefined;
      }
    }
  }

  invalidateWindowStage(): void {
    if (this.disposed) {
      return;
    }
    this.windowStageGeneration += 1;
    this.windowStageReady = false;
    this.windowStage = undefined;
    this.cancelCallsWithMissingContext();
    this.notifyContextChanged();
  }

  async emitLifecycle(event: BridgeLifecycleEvent): Promise<void> {
    if (this.disposed) {
      return;
    }
    await this.enqueueLifecycle(event.kind, async (): Promise<void> => {
      await this.deliverLifecycle(event);
    });
  }

  private async deliverLifecycle(event: BridgeLifecycleEvent): Promise<void> {
    if (!this.closing) {
      await this.activateReadyPlugins();
    }
    this.recordLifecycle(event);
    const entries = Array.from(this.plugins.values());
    const deliveries: Promise<void>[] = [];
    for (const entry of entries) {
      if (!entry.installed || entry.hookError !== undefined || !entry.plugin.onLifecycle) {
        continue;
      }
      deliveries.push(this.deliverPluginLifecycle(entry, event));
    }
    await Promise.all(deliveries);
  }

  private async deliverPluginLifecycle(
    entry: HostedPlugin,
    event: BridgeLifecycleEvent,
  ): Promise<void> {
    try {
      await this.runPluginHook(
        entry.plugin.id,
        `lifecycle '${event.kind}'`,
        async (context: BridgePluginHookContext): Promise<void> => {
          await entry.plugin.onLifecycle!(event, context);
        },
      );
    } catch (error) {
      this.recordHookFailure(entry, error);
      console.error(
        `[BridgeHost:${this.moduleName}] plugin '${entry.plugin.id}' failed lifecycle '${event.kind}': ${String(error)}`,
      );
    }
  }

  async invokeAsync(
    pluginId: string,
    pluginVersion: number,
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
    timeoutMs: number,
  ): Promise<ESObject> {
    const request: BridgeTypedValue = { typeName: requestTypeName, value };
    this.assertWireCall(pluginId, pluginVersion, action, request, responseTypeName);
    const entry = this.lookup(pluginId, pluginVersion);
    if (entry.plugin.execution !== "async") {
      throw new Error(
        `Bridge plugin '${pluginId}' is synchronous and must be called through bridgeInvokeSync`,
      );
    }

    const asyncPlugin: AsyncBridgePlugin = entry.plugin as AsyncBridgePlugin;
    const boundedTimeoutMs = clampTimeout(timeoutMs);
    const callState: BridgeCallState = { pluginId, cancelled: false, cancelListeners: [] };
    const cancellation = new Promise<BridgeTypedValue>((_resolve, reject) => {
      callState.rejectCancellation = reject;
    });
    this.activeCalls.push(callState);
    const operation = Promise.resolve()
      .then(async (): Promise<BridgeTypedValue> => {
        await this.ensureActive(entry, callState);
        this.assertCallActive(pluginId, action, callState, "before invocation");
        const result = await asyncPlugin.invokeAsync(
          action,
          request,
          this.callContext(pluginId, action, boundedTimeoutMs, callState),
        );
        this.assertCallActive(pluginId, action, callState, "after invocation");
        this.assertResponsePayload(pluginId, action, responseTypeName, result);
        return result;
      })
      .finally(() => {
        this.removeActiveCall(callState);
      });

    const result = await this.withTimeout(
      Promise.race([operation, cancellation]),
      boundedTimeoutMs,
      pluginId,
      action,
      (reason: Error) => {
        this.cancelCall(callState, reason);
      },
    );
    return result.value;
  }

  invokeSync(
    pluginId: string,
    pluginVersion: number,
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ): ESObject {
    const request: BridgeTypedValue = { typeName: requestTypeName, value };
    this.assertWireCall(pluginId, pluginVersion, action, request, responseTypeName);
    const entry = this.lookup(pluginId, pluginVersion);
    if (entry.plugin.execution !== "sync-main-thread") {
      throw new Error(
        `Bridge plugin '${pluginId}' is asynchronous and must be called through bridgeInvoke`,
      );
    }
    if (!this.requirementsReady(entry)) {
      throw new Error(
        `Synchronous bridge plugin '${pluginId}' is not ready: ${this.missingRequirements(entry).join(", ")}`,
      );
    }
    if (!entry.installed) {
      throw new Error(
        `Synchronous bridge plugin '${pluginId}' is still installing; invoke it from a later main-thread callback`,
      );
    }

    const syncPlugin: MainThreadSyncBridgePlugin = entry.plugin as MainThreadSyncBridgePlugin;
    const syncCallState: BridgeCallState = {
      pluginId,
      cancelled: false,
      cancelListeners: [],
    };
    const result = syncPlugin.invokeSync(
      action,
      request,
      this.callContext(pluginId, action, 0, syncCallState),
    );
    this.assertResponsePayload(pluginId, action, responseTypeName, result);
    return result.value;
  }

  private invokeNativeSync(
    pluginId: string,
    event: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ): ESObject {
    this.assertActive();
    if (
      !isBridgeIdentifier(pluginId) ||
      !isBridgeIdentifier(event) ||
      !isBridgeIdentifier(requestTypeName) ||
      !isBridgeIdentifier(responseTypeName)
    ) {
      throw new Error("Invalid main-thread bridge plugin id, event or type name");
    }
    this.assertTypedValue({ typeName: requestTypeName, value }, "main-thread request");
    const sink = this.mainThreadEventSink;
    if (sink === undefined) {
      throw new Error(
        "Main-thread event sink is unavailable because the native module is not rendered",
      );
    }
    const entry = this.plugins.get(pluginId);
    if (entry?.hookError !== undefined) {
      throw new Error(entry.hookError);
    }
    return sink(pluginId, event, requestTypeName, responseTypeName, value);
  }

  attachEventSink(
    mainThreadSink: BridgeMainThreadEventSink | undefined,
    lifecycleSink: BridgeLifecycleSink | undefined,
  ): number {
    this.assertActive();
    this.mainThreadEventSink = mainThreadSink;
    this.lifecycleSink = lifecycleSink;
    this.eventSinkToken += 1;
    return this.eventSinkToken;
  }

  detachEventSink(token?: number): void {
    if (token !== undefined && token !== this.eventSinkToken) {
      return;
    }
    this.mainThreadEventSink = undefined;
    this.lifecycleSink = undefined;
  }

  beginClosing(): void {
    if (this.closing || this.disposed) {
      return;
    }
    this.closing = true;
    const activeCalls = this.activeCalls.splice(0, this.activeCalls.length);
    for (const callState of activeCalls) {
      this.cancelCall(
        callState,
        new Error(`Bridge session '${this.sessionId}' is closing while a call is pending`),
      );
    }
    const activeHooks = this.activeHooks.slice();
    for (const hook of activeHooks) {
      hook.scope.cancel(
        new Error(
          `Bridge session '${this.sessionId}' is closing during plugin hook '${hook.label}'`,
        ),
      );
    }
    this.notifyContextChanged();
  }

  async dispose(): Promise<void> {
    if (this.disposePromise !== undefined) {
      await this.disposePromise;
      return;
    }
    this.beginClosing();
    this.disposePromise = this.enqueueLifecycle("dispose", async (): Promise<void> => {
      const entries = Array.from(this.plugins.values());
      await Promise.all(
        entries.map(async (entry: HostedPlugin): Promise<void> => await this.disposePlugin(entry)),
      );
      this.plugins.clear();
      this.mainThreadEventSink = undefined;
      this.lifecycleSink = undefined;
      for (const pending of this.pendingWindows.values()) {
        pending.cancelled = true;
      }
      this.pendingWindows.clear();
      // Release every window surface: keyed mounts first, then handle-owned nodes. The root
      // FrameNodes themselves are owned and disposed by their DefaultXComponent instances.
      for (const state of this.windows.values()) {
        this.disposeWindowState(state);
      }
      this.windows.clear();
      this.abilityReady = false;
      this.uiContextReady = false;
      this.windowStage = undefined;
      this.windowStageReady = false;
      this.disposed = true;
      this.notifyContextChanged();
    });
    await this.disposePromise;
  }

  private async disposePlugin(entry: HostedPlugin): Promise<void> {
    try {
      if (entry.installing !== undefined) {
        try {
          await entry.installing;
        } catch {}
      }
      if (entry.installAttempted && entry.plugin.onDispose) {
        await this.runPluginHook(
          entry.plugin.id,
          "dispose",
          async (context: BridgePluginHookContext): Promise<void> => {
            await entry.plugin.onDispose!(context);
          },
        );
      }
    } catch (error) {
      console.error(
        `[BridgeHost:${this.moduleName}] plugin '${entry.plugin.id}' failed dispose: ${String(error)}`,
      );
    }
  }

  private async ensureActive(entry: HostedPlugin, callState?: BridgeCallState): Promise<void> {
    while (!this.requirementsReady(entry)) {
      this.assertCallStateActive(callState);
      await this.waitForContextChange(callState);
    }
    this.assertCallStateActive(callState);
    await this.activate(entry);
    this.assertCallStateActive(callState);
  }

  private async activateReadyPlugins(): Promise<void> {
    const entries = Array.from(this.plugins.values());
    const activations: Promise<void>[] = [];
    for (const entry of entries) {
      if (entry.installError !== undefined || entry.hookError !== undefined) {
        continue;
      }
      if (this.requirementsReady(entry)) {
        activations.push(this.activateReadyPlugin(entry));
      }
    }
    await Promise.all(activations);
  }

  private async activateReadyPlugin(entry: HostedPlugin): Promise<void> {
    try {
      await this.activate(entry);
    } catch (error) {
      console.error(
        `[BridgeHost:${this.moduleName}] plugin '${entry.plugin.id}' failed to install: ${String(error)}`,
      );
    }
  }

  private async activate(entry: HostedPlugin): Promise<void> {
    if (entry.installed) {
      return;
    }
    if (!this.requirementsReady(entry)) {
      return;
    }
    if (entry.installError !== undefined) {
      throw new Error(entry.installError);
    }
    if (entry.hookError !== undefined) {
      throw new Error(entry.hookError);
    }
    if (!entry.installing) {
      entry.installing = Promise.resolve()
        .then(async () => {
          entry.installAttempted = true;
          try {
            if (entry.plugin.onInstall) {
              await this.runPluginHook(
                entry.plugin.id,
                "install",
                async (context: BridgePluginHookContext): Promise<void> => {
                  await entry.plugin.onInstall!(context);
                },
              );
            }
            entry.installed = true;
            await this.replayLifecycle(entry);
          } catch (error) {
            if (!entry.installed) {
              entry.installError = `Bridge plugin '${entry.plugin.id}' install failed: ${String(error)}`;
            }
            throw new Error(String(error));
          }
        })
        .finally(() => {
          entry.installing = undefined;
        });
    }
    await entry.installing;
  }

  private async replayLifecycle(entry: HostedPlugin): Promise<void> {
    if (!entry.plugin.onLifecycle) {
      return;
    }
    for (const event of this.lifecycleHistory) {
      try {
        await this.runPluginHook(
          entry.plugin.id,
          `replay lifecycle '${event.kind}'`,
          async (context: BridgePluginHookContext): Promise<void> => {
            await entry.plugin.onLifecycle!(event, context);
          },
        );
      } catch (error) {
        this.recordHookFailure(entry, error);
        console.error(
          `[BridgeHost:${this.moduleName}] plugin '${entry.plugin.id}' failed replay lifecycle '${event.kind}': ${String(error)}`,
        );
        if (entry.hookError !== undefined) {
          return;
        }
      }
    }
  }

  private requirementsReady(entry: HostedPlugin): boolean {
    return this.missingRequirements(entry).length === 0;
  }

  private missingRequirements(entry: HostedPlugin): BridgeContextRequirement[] {
    const missing: BridgeContextRequirement[] = [];
    // Every plugin belongs to an Ability session, even when it declares no additional platform
    // objects. This also guarantees Rust sinks exist before the first onInstall callback.
    if (!this.abilityReady) {
      missing.push("ability");
    }
    for (const requirement of normalizedRequirements(entry.plugin.requires)) {
      if (requirement === "window-stage" && !this.windowStageReady) {
        missing.push(requirement);
      }
      if (requirement === "ui-context" && !this.uiContextReady) {
        missing.push(requirement);
      }
    }
    return missing;
  }

  private pluginContext(pluginId: string): BridgePluginContext {
    const mainScope = this.windowScope(MAIN_WINDOW_KEY);
    return {
      pluginId,
      moduleName: this.moduleName,
      sessionId: this.sessionId,
      abilityContext: this.abilityContext,
      isActive: (): boolean =>
        this.abilityReady && !this.closing && !this.disposed && this.pluginOperational(pluginId),
      getWindowStage: (): window.WindowStage => {
        if (this.windowStage === undefined) {
          throw new Error(`Bridge plugin '${pluginId}' requires a WindowStage that is not ready`);
        }
        return this.windowStage;
      },
      getUIContext: (): UIContext => mainScope.getUIContext(),
      getRootFrameNode: (): FrameNode => mainScope.getRootFrameNode(),
      appendChild: (key: string, node: FrameNode, cleanup?: () => void): void =>
        mainScope.appendChild(key, node, cleanup),
      removeChild: (key: string): void => mainScope.removeChild(key),
      getFrameNode: (handle: number): FrameNode => mainScope.getFrameNode(handle),
      windowScope: (windowKey: string): BridgeWindowScope => this.windowScope(windowKey),
      invokeNativeSync: (
        event: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject =>
        this.invokeNativeSync(pluginId, event, requestTypeName, responseTypeName, value),
    };
  }

  private callContext(
    pluginId: string,
    action: string,
    timeoutMs: number,
    callState: BridgeCallState,
  ): BridgeCallContext {
    const context = this.pluginContext(pluginId);
    return {
      pluginId,
      moduleName: this.moduleName,
      sessionId: this.sessionId,
      abilityContext: this.abilityContext,
      action,
      timeoutMs,
      isActive: (): boolean =>
        !this.closing &&
        !this.disposed &&
        !callState.cancelled &&
        this.pluginRequirementsReady(pluginId),
      isCancelled: (): boolean => this.closing || this.disposed || callState.cancelled,
      onCancel: (listener: () => void): (() => void) =>
        this.subscribeCancellation(callState, listener),
      getWindowStage: (): window.WindowStage => context.getWindowStage(),
      getUIContext: (): UIContext => context.getUIContext(),
      getRootFrameNode: (): FrameNode => context.getRootFrameNode(),
      appendChild: (key: string, node: FrameNode, cleanup?: () => void): void =>
        context.appendChild(key, node, cleanup),
      removeChild: (key: string): void => context.removeChild(key),
      getFrameNode: (handle: number): FrameNode => context.getFrameNode(handle),
      windowScope: (windowKey: string): BridgeWindowScope => context.windowScope(windowKey),
      invokeNativeSync: (
        event: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject =>
        this.invokeNativeSync(pluginId, event, requestTypeName, responseTypeName, value),
    };
  }

  private pluginHookContext(
    pluginId: string,
    signal: TaskCancellationSignal,
  ): BridgePluginHookContext {
    const context = this.pluginContext(pluginId);
    return {
      pluginId,
      moduleName: this.moduleName,
      sessionId: this.sessionId,
      abilityContext: this.abilityContext,
      isActive: (): boolean => context.isActive() && !signal.isCancelled(),
      isCancelled: (): boolean => signal.isCancelled() || this.disposed,
      onCancel: (listener: () => void): (() => void) => signal.onCancel(listener),
      getWindowStage: (): window.WindowStage => context.getWindowStage(),
      getUIContext: (): UIContext => context.getUIContext(),
      getRootFrameNode: (): FrameNode => context.getRootFrameNode(),
      appendChild: (key: string, node: FrameNode, cleanup?: () => void): void =>
        context.appendChild(key, node, cleanup),
      removeChild: (key: string): void => context.removeChild(key),
      getFrameNode: (handle: number): FrameNode => context.getFrameNode(handle),
      windowScope: (windowKey: string): BridgeWindowScope => context.windowScope(windowKey),
      invokeNativeSync: (
        event: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject =>
        this.invokeNativeSync(pluginId, event, requestTypeName, responseTypeName, value),
    };
  }

  private async runPluginHook(
    pluginId: string,
    label: string,
    operation: (context: BridgePluginHookContext) => Promise<void>,
  ): Promise<void> {
    const scope = new CancellableTaskScope(
      `Bridge plugin '${pluginId}' hook '${label}'`,
      PLUGIN_HOOK_TIMEOUT_MS,
    );
    const activeHook: ActivePluginHook = {
      label,
      scope,
    };
    this.activeHooks.push(activeHook);
    try {
      await scope.run(async (signal: TaskCancellationSignal): Promise<void> => {
        await operation(this.pluginHookContext(pluginId, signal));
      });
    } catch (error) {
      if (scope.didTimeOut()) {
        throw new Error(`${PLUGIN_HOOK_TIMEOUT_PREFIX}${String(error)}`);
      }
      throw new Error(String(error));
    } finally {
      const index = this.activeHooks.indexOf(activeHook);
      if (index >= 0) {
        this.activeHooks.splice(index, 1);
      }
    }
  }

  private recordLifecycle(event: BridgeLifecycleEvent): void {
    const needsReplay = Array.from(this.plugins.values()).some(
      (entry: HostedPlugin): boolean =>
        !entry.installed && entry.installError === undefined && entry.hookError === undefined,
    );
    if (!needsReplay) {
      this.lifecycleHistory.splice(0, this.lifecycleHistory.length);
      return;
    }
    if (this.lifecycleHistory.length >= MAX_LIFECYCLE_HISTORY) {
      const evictableIndex = this.lifecycleHistory.findIndex(
        (recorded: BridgeLifecycleEvent): boolean =>
          recorded.kind === "configuration-updated" ||
          recorded.kind === "memory-level" ||
          recorded.kind === "window-stage-event" ||
          recorded.kind === "window-detached",
      );
      if (evictableIndex >= 0) {
        this.lifecycleHistory.splice(evictableIndex, 1);
      } else {
        // Preserve the session's ability-create anchor when possible, but never let a long-lived
        // sequence of structural events turn the replay buffer into unbounded process state.
        this.lifecycleHistory.splice(this.lifecycleHistory.length > 1 ? 1 : 0, 1);
      }
    }
    this.lifecycleHistory.push(event);
  }

  private recordHookFailure(entry: HostedPlugin, error: ESObject): void {
    if (String(error).indexOf(PLUGIN_HOOK_TIMEOUT_PREFIX) < 0 || entry.hookError !== undefined) {
      return;
    }
    entry.hookError = `Bridge plugin '${entry.plugin.id}' was disabled after a lifecycle hook timeout: ${String(error)}`;
    for (const callState of this.activeCalls.slice()) {
      if (callState.pluginId === entry.plugin.id) {
        this.cancelCall(callState, new Error(entry.hookError));
      }
    }
  }

  private pluginOperational(pluginId: string): boolean {
    const entry = this.plugins.get(pluginId);
    return entry !== undefined && entry.hookError === undefined;
  }

  private notifyContextChanged(): void {
    const waiters = this.contextWaiters.splice(0, this.contextWaiters.length);
    for (const resolve of waiters) {
      resolve();
    }
  }

  private enqueueLifecycle(label: string, operation: () => Promise<void>): Promise<void> {
    return this.lifecycleQueue.enqueue(label, operation);
  }

  private notifyRustLifecycle(kind: string): void {
    const sink = this.lifecycleSink;
    if (sink === undefined) {
      return;
    }
    try {
      sink(kind);
    } catch (error) {
      console.error(
        `[BridgeHost:${this.moduleName}] Rust lifecycle '${kind}' failed: ${String(error)}`,
      );
    }
  }

  private pluginRequirementsReady(pluginId: string): boolean {
    const entry = this.plugins.get(pluginId);
    return entry !== undefined && entry.hookError === undefined && this.requirementsReady(entry);
  }

  private cancelCallsWithMissingContext(): void {
    for (const callState of this.activeCalls.slice()) {
      if (this.pluginRequirementsReady(callState.pluginId)) {
        continue;
      }
      this.cancelCall(
        callState,
        new Error(
          `Bridge plugin '${callState.pluginId}' lost its required context while a call was pending`,
        ),
      );
    }
  }

  private async waitForContextChange(callState?: BridgeCallState): Promise<void> {
    await new Promise<void>((resolve) => {
      let settled = false;
      let unsubscribe: () => void = (): void => {};
      const wake = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        const index = this.contextWaiters.indexOf(wake);
        if (index >= 0) {
          this.contextWaiters.splice(index, 1);
        }
        unsubscribe();
        resolve();
      };
      this.contextWaiters.push(wake);
      if (callState !== undefined) {
        unsubscribe = this.subscribeCancellation(callState, wake);
      }
    });
  }

  private assertCallStateActive(callState?: BridgeCallState): void {
    if (this.closing || this.disposed) {
      throw new Error(`Bridge session '${this.sessionId}' is closing or already disposed`);
    }
    if (callState?.cancelled) {
      throw new Error(`Bridge call for session '${this.sessionId}' was cancelled`);
    }
  }

  private assertCallActive(
    pluginId: string,
    action: string,
    callState: BridgeCallState,
    phase: string,
  ): void {
    if (
      this.closing ||
      this.disposed ||
      callState.cancelled ||
      !this.pluginRequirementsReady(pluginId)
    ) {
      throw new Error(`Bridge call '${pluginId}.${action}' was cancelled ${phase}`);
    }
  }

  private cancelCall(callState: BridgeCallState, reason?: Error): void {
    if (callState.cancelled) {
      return;
    }
    callState.cancelled = true;
    const listeners = callState.cancelListeners.splice(0, callState.cancelListeners.length);
    for (const listener of listeners) {
      try {
        listener();
      } catch {
        // Cancellation is best-effort. One plugin listener must not block the rest.
      }
    }
    const rejectCancellation = callState.rejectCancellation;
    callState.rejectCancellation = undefined;
    if (rejectCancellation !== undefined) {
      rejectCancellation(reason ?? new Error("Bridge call was cancelled"));
    }
  }

  private subscribeCancellation(callState: BridgeCallState, listener: () => void): () => void {
    if (callState.cancelled || this.closing || this.disposed) {
      listener();
      return (): void => {};
    }
    callState.cancelListeners.push(listener);
    return (): void => {
      const index = callState.cancelListeners.indexOf(listener);
      if (index >= 0) {
        callState.cancelListeners.splice(index, 1);
      }
    };
  }

  private removeActiveCall(callState: BridgeCallState): void {
    const index = this.activeCalls.indexOf(callState);
    if (index >= 0) {
      this.activeCalls.splice(index, 1);
    }
  }

  private lookup(pluginId: string, pluginVersion: number): HostedPlugin {
    this.assertActive();
    const entry = this.plugins.get(pluginId);
    if (!entry) {
      throw new Error(`Bridge plugin '${pluginId}' is not installed for '${this.moduleName}'`);
    }
    if (entry.hookError !== undefined) {
      throw new Error(entry.hookError);
    }
    if (entry.plugin.version !== pluginVersion) {
      throw new Error(
        `Bridge plugin '${pluginId}' version mismatch: Rust=${pluginVersion}, ArkTS=${entry.plugin.version}`,
      );
    }
    return entry;
  }

  private assertWireCall(
    pluginId: string,
    pluginVersion: number,
    action: string,
    request: BridgeTypedValue,
    responseTypeName: string,
  ): void {
    this.assertActive();
    if (!isBridgeIdentifier(pluginId) || !isBridgeIdentifier(action) || pluginVersion <= 0) {
      throw new Error("Invalid bridge plugin id, version or action");
    }
    if (!isBridgeIdentifier(responseTypeName)) {
      throw new Error("Invalid bridge response type name");
    }
    this.assertTypedValue(request, "request");
  }

  private assertTypedValue(payload: BridgeTypedValue, role: string): void {
    if (!payload || !isBridgeIdentifier(payload.typeName)) {
      throw new Error(`Bridge ${role} must declare a valid type name`);
    }
    const value: ESObject = payload.value;
    if (value === undefined || typeof value === "function" || typeof value === "symbol") {
      throw new Error(`Bridge ${role} '${payload.typeName}' is not an N-API data value`);
    }
    if (
      (typeof value === "string" || value instanceof Uint8Array) &&
      value.length > MAX_PAYLOAD_BYTES
    ) {
      throw new Error(`Bridge ${role} exceeds ${MAX_PAYLOAD_BYTES} bytes`);
    }
  }

  private assertResponsePayload(
    pluginId: string,
    action: string,
    responseTypeName: string,
    response: BridgeTypedValue,
  ): void {
    this.assertTypedValue(response, "response");
    if (response.typeName !== responseTypeName) {
      throw new Error(
        `Bridge plugin '${pluginId}.${action}' returned ${response.typeName}, expected ${responseTypeName}`,
      );
    }
  }

  private assertActive(): void {
    if (this.closing || this.disposed) {
      throw new Error(`Bridge session '${this.sessionId}' is closing or already disposed`);
    }
  }

  private validateFactory(factory: BridgePluginFactory): void {
    if (typeof factory.create !== "function") {
      throw new Error(`Invalid bridge plugin factory for module ${this.moduleName}`);
    }
  }

  private validatePlugin(plugin: BridgePlugin): void {
    if (!isBridgeIdentifier(plugin.id) || plugin.version <= 0) {
      throw new Error(`Invalid bridge plugin declaration for module ${this.moduleName}`);
    }
    for (const requirement of normalizedRequirements(plugin.requires)) {
      if (
        requirement !== "ability" &&
        requirement !== "window-stage" &&
        requirement !== "ui-context"
      ) {
        throw new Error(`Invalid context requirement '${requirement}' for '${plugin.id}'`);
      }
    }
  }

  private async withTimeout(
    operation: Promise<BridgeTypedValue>,
    timeoutMs: number,
    pluginId: string,
    action: string,
    onTimeout: (reason: Error) => void,
  ): Promise<BridgeTypedValue> {
    let timer = 0;
    const timeout = new Promise<BridgeTypedValue>((_resolve, reject) => {
      timer = setTimeout(() => {
        const reason = new Error(
          `Bridge call '${pluginId}.${action}' timed out after ${timeoutMs}ms`,
        );
        onTimeout(reason);
        reject(reason);
      }, timeoutMs);
    });
    try {
      return await Promise.race([operation, timeout]);
    } finally {
      clearTimeout(timer);
    }
  }
}

/**
 * Session registry is transport plumbing only. It is keyed by a NativeAbility-created session
 * instead of a process-global Helper, so stale calls cannot reach a recreated ability instance.
 */
export class BridgeHostRegistry {
  private static readonly sessions: Map<string, Map<string, BridgeHost>> = new Map();
  private static nextSession: number = 1;

  static prepare(
    moduleNames: string[],
    abilityContext: common.UIAbilityContext,
    factories: BridgePluginFactory[],
  ): string {
    const sessionId = `bridge-${Date.now()}-${BridgeHostRegistry.nextSession++}`;
    const hosts: Map<string, BridgeHost> = new Map();
    try {
      for (const moduleName of moduleNames) {
        const host = new BridgeHost(sessionId, moduleName, abilityContext);
        hosts.set(moduleName, host);
        host.registerFactories(factories);
      }
    } catch (error) {
      throw new Error(String(error));
    }
    BridgeHostRegistry.sessions.set(sessionId, hosts);
    return sessionId;
  }

  static async activateAbility(
    sessionId: string,
    moduleName: string,
    event: BridgeLifecycleEvent,
  ): Promise<void> {
    await BridgeHostRegistry.host(sessionId, moduleName).activateAbility(event);
  }

  static async invokeAsync(
    sessionId: string,
    moduleName: string,
    pluginId: string,
    pluginVersion: number,
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
    timeoutMs: number,
  ): Promise<ESObject> {
    return await BridgeHostRegistry.host(sessionId, moduleName).invokeAsync(
      pluginId,
      pluginVersion,
      action,
      requestTypeName,
      responseTypeName,
      value,
      timeoutMs,
    );
  }

  static invokeSync(
    sessionId: string,
    moduleName: string,
    pluginId: string,
    pluginVersion: number,
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ): ESObject {
    return BridgeHostRegistry.host(sessionId, moduleName).invokeSync(
      pluginId,
      pluginVersion,
      action,
      requestTypeName,
      responseTypeName,
      value,
    );
  }

  static async setWindowStage(
    sessionId: string,
    moduleName: string,
    windowStage: window.WindowStage,
  ): Promise<void> {
    await BridgeHostRegistry.host(sessionId, moduleName).setWindowStage(windowStage);
  }

  static async clearWindowStage(sessionId: string, moduleName: string): Promise<void> {
    await BridgeHostRegistry.host(sessionId, moduleName).clearWindowStage();
  }

  static invalidateWindowStage(sessionId: string, moduleName: string): void {
    BridgeHostRegistry.sessions.get(sessionId)?.get(moduleName)?.invalidateWindowStage();
  }

  /**
   * Registers one window's node surface (`windowKey` defaults to `"main"`). Attaching the main
   * window emits `ui-context-ready`, so plugins can mount nodes during `onInstall` without any
   * waiting; sub-window attachments only register state.
   */
  static async attachWindow(
    sessionId: string,
    moduleName: string,
    windowKey: string,
    uiContext: UIContext,
    root: FrameNode,
  ): Promise<void> {
    await BridgeHostRegistry.host(sessionId, moduleName).attachWindow(windowKey, uiContext, root);
  }

  /** Unregisters one window's node surface. The root node itself is disposed by its owner. */
  static async detachWindow(
    sessionId: string,
    moduleName: string,
    windowKey: string,
  ): Promise<void> {
    const host = BridgeHostRegistry.sessions.get(sessionId)?.get(moduleName);
    await host?.detachWindow(windowKey);
  }

  static async emitLifecycle(
    sessionId: string,
    moduleName: string,
    event: BridgeLifecycleEvent,
  ): Promise<void> {
    await BridgeHostRegistry.host(sessionId, moduleName).emitLifecycle(event);
  }

  static attachEventSink(
    sessionId: string,
    moduleName: string,
    mainThreadSink: BridgeMainThreadEventSink | undefined,
    lifecycleSink?: BridgeLifecycleSink,
  ): number {
    return BridgeHostRegistry.host(sessionId, moduleName).attachEventSink(
      mainThreadSink,
      lifecycleSink,
    );
  }

  static detachEventSink(sessionId: string, moduleName: string, token?: number): void {
    const host = BridgeHostRegistry.sessions.get(sessionId)?.get(moduleName);
    host?.detachEventSink(token);
  }

  static beginClosing(sessionId: string): void {
    const hosts = BridgeHostRegistry.sessions.get(sessionId);
    if (hosts === undefined) {
      return;
    }
    for (const host of hosts.values()) {
      host.beginClosing();
    }
  }

  static async dispose(sessionId: string): Promise<void> {
    const hosts = BridgeHostRegistry.sessions.get(sessionId);
    if (!hosts) {
      return;
    }
    BridgeHostRegistry.sessions.delete(sessionId);
    await BridgeHostRegistry.disposeHosts(hosts);
  }

  private static host(sessionId: string, moduleName: string): BridgeHost {
    const host = BridgeHostRegistry.sessions.get(sessionId)?.get(moduleName);
    if (!host) {
      throw new Error(
        `No bridge host for module '${moduleName}'. NativeAbility may have been destroyed or is not hosting this XComponent.`,
      );
    }
    return host;
  }

  private static async disposeHosts(hosts: Map<string, BridgeHost>): Promise<void> {
    const values = Array.from(hosts.values());
    await Promise.all(values.map(async (host: BridgeHost): Promise<void> => await host.dispose()));
    hosts.clear();
  }
}
