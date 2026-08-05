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
  BridgeWindowScope,
} from "../ability/type";

const MAX_TIMEOUT_MS = 60_000;
const MAX_PAYLOAD_BYTES = 512 * 1024;
const MAX_LIFECYCLE_HISTORY = 16;

type BridgeMainThreadEventSink = (
  pluginId: string,
  event: string,
  requestTypeName: string,
  responseTypeName: string,
  value: ESObject,
) => ESObject;

interface HostedPlugin {
  factory: BridgePluginFactory;
  plugin: BridgePlugin;
  installed: boolean;
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
  cancelled: boolean;
  cancelListeners: Array<() => void>;
  rejectCancellation?: (reason: Error) => void;
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
  private mainThreadEventSink?: BridgeMainThreadEventSink;
  private windowStage?: window.WindowStage;
  private disposed: boolean = false;
  private readonly sessionId: string;
  private readonly moduleName: string;
  private readonly abilityContext: common.UIAbilityContext;
  // Per-window node surfaces: every `DefaultXComponent` instance (one per window) registers its
  // own root FrameNode under its `windowKey` (`"main"` by default), so sub-window plugin trees
  // never overwrite the main window's. Each window owns its keyed mounts and the opaque handle
  // table of the built-in ohos.node plugin.
  private readonly windows: Map<string, HostWindowState> = new Map();

  constructor(sessionId: string, moduleName: string, abilityContext: common.UIAbilityContext) {
    this.sessionId = sessionId;
    this.moduleName = moduleName;
    this.abilityContext = abilityContext;
  }

  async install(factories: BridgePluginFactory[]): Promise<void> {
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
      this.plugins.set(plugin.id, { factory, plugin, installed: false });
    }
    await this.activateReadyPlugins();
  }

  /**
   * Installs the built-in `ohos.node` surface plugin ahead of business plugins. It closes over
   * this host so its actions operate on the session root and handle table directly.
   */
  private installNodeSurfacePlugin(): void {
    const plugin = new NodeSurfacePlugin(this);
    this.plugins.set(plugin.id, {
      factory: { create: (): BridgePlugin => plugin },
      plugin,
      installed: false,
    });
  }

  /**
   * Registers one window's node surface. `DefaultXComponent` calls this from `aboutToAppear`
   * after creating its root. Attaching the `"main"` window emits `ui-context-ready` (and wakes
   * context waiters); sub-window attachments only register state.
   */
  attachWindow(windowKey: string, uiContext: UIContext, root: FrameNode): void {
    this.assertActive();
    this.assertWindowKey(windowKey);
    if (this.windows.has(windowKey)) {
      throw new Error(
        `Bridge window '${windowKey}' is already attached for '${this.moduleName}'; each DefaultXComponent needs a unique windowKey`,
      );
    }
    this.windows.set(windowKey, {
      uiContext,
      rootFrameNode: root,
      mountedChildren: new Map(),
      nodeHandles: new Map(),
      nodeParents: new Map(),
      nextNodeHandle: 1,
    });
    if (windowKey === MAIN_WINDOW_KEY) {
      this.notifyContextChanged();
      void this.emitLifecycle({
        kind: "ui-context-ready",
        payload: new BridgeEmptyLifecyclePayload(),
      });
    }
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
    const state = this.windows.get(windowKey);
    if (state === undefined) {
      return;
    }
    if (windowKey === MAIN_WINDOW_KEY) {
      await this.emitLifecycle({
        kind: "ui-context-destroy",
        payload: new BridgeEmptyLifecyclePayload(),
      });
    }
    this.disposeWindowState(state);
    this.windows.delete(windowKey);
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
    parent.appendChild(child);
    state.nodeParents.set(childHandle, parent);
  }

  /** Appends a handle-owned node to the `windowKey` root (ohos.node). */
  mountIntoRoot(windowKey: string, handle: number): void {
    const state = this.requireWindow(windowKey);
    const node = this.lookupNodeHandle(state, handle, "mount-into-root");
    const root = this.requireRootFrameNode(state);
    root.appendChild(node);
    state.nodeParents.set(handle, root);
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
    this.requireRootFrameNode(state).appendChild(node);
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

  async setWindowStage(windowStage: window.WindowStage): Promise<void> {
    this.assertActive();
    this.windowStage = windowStage;
    this.notifyContextChanged();
    await this.emitLifecycle({
      kind: "window-stage-create",
      payload: new BridgeEmptyLifecyclePayload(),
    });
  }

  async clearWindowStage(): Promise<void> {
    if (this.disposed) {
      return;
    }
    // The WindowStage belongs to the Ability (main window). Detach every registered window
    // surface; only the main window emits `ui-context-destroy`.
    const windowKeys = Array.from(this.windows.keys());
    for (const windowKey of windowKeys) {
      await this.detachWindow(windowKey);
    }
    await this.emitLifecycle({
      kind: "window-stage-destroy",
      payload: new BridgeEmptyLifecyclePayload(),
    });
    this.windowStage = undefined;
  }

  async emitLifecycle(event: BridgeLifecycleEvent): Promise<void> {
    if (this.disposed) {
      return;
    }
    await this.activateReadyPlugins();
    this.recordLifecycle(event);
    const entries = Array.from(this.plugins.values());
    for (const entry of entries) {
      if (!entry.installed || !entry.plugin.onLifecycle) {
        continue;
      }
      await entry.plugin.onLifecycle(event, this.pluginContext(entry.plugin.id));
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
    const callState: BridgeCallState = { cancelled: false, cancelListeners: [] };
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
    const syncCallState: BridgeCallState = { cancelled: false, cancelListeners: [] };
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
    return sink(pluginId, event, requestTypeName, responseTypeName, value);
  }

  attachEventSink(mainThreadSink: BridgeMainThreadEventSink): void {
    this.assertActive();
    this.mainThreadEventSink = mainThreadSink;
  }

  detachEventSink(): void {
    this.mainThreadEventSink = undefined;
  }

  async dispose(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    const activeCalls = this.activeCalls.splice(0, this.activeCalls.length);
    for (const callState of activeCalls) {
      this.cancelCall(
        callState,
        new Error(`Bridge session '${this.sessionId}' was disposed while a call was pending`),
      );
    }
    this.notifyContextChanged();
    const entries = Array.from(this.plugins.values());
    for (const entry of entries) {
      try {
        if (entry.installed && entry.plugin.onDispose) {
          await entry.plugin.onDispose(this.pluginContext(entry.plugin.id));
        }
      } catch {
        // Teardown must not prevent another plugin from releasing its resources.
      }
    }
    this.plugins.clear();
    this.mainThreadEventSink = undefined;
    // Release every window surface: keyed mounts first, then handle-owned nodes. The root
    // FrameNodes themselves are owned and disposed by their DefaultXComponent instances.
    const windowKeys = Array.from(this.windows.keys());
    for (const windowKey of windowKeys) {
      const state = this.windows.get(windowKey);
      if (state !== undefined) {
        this.disposeWindowState(state);
      }
    }
    this.windows.clear();
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
    for (const entry of entries) {
      if (this.requirementsReady(entry)) {
        await this.activate(entry);
      }
    }
  }

  private async activate(entry: HostedPlugin): Promise<void> {
    if (entry.installed) {
      return;
    }
    if (!this.requirementsReady(entry)) {
      return;
    }
    if (!entry.installing) {
      entry.installing = Promise.resolve()
        .then(async () => {
          if (entry.plugin.onInstall) {
            await entry.plugin.onInstall(this.pluginContext(entry.plugin.id));
          }
          entry.installed = true;
          await this.replayLifecycle(entry);
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
      await entry.plugin.onLifecycle(event, this.pluginContext(entry.plugin.id));
    }
  }

  private requirementsReady(entry: HostedPlugin): boolean {
    return this.missingRequirements(entry).length === 0;
  }

  private missingRequirements(entry: HostedPlugin): BridgeContextRequirement[] {
    const missing: BridgeContextRequirement[] = [];
    for (const requirement of normalizedRequirements(entry.plugin.requires)) {
      if (requirement === "window-stage" && this.windowStage === undefined) {
        missing.push(requirement);
      }
      if (requirement === "ui-context" && !this.windows.has(MAIN_WINDOW_KEY)) {
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
      isActive: (): boolean => !this.disposed,
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
      isActive: (): boolean => !this.disposed && !callState.cancelled,
      isCancelled: (): boolean => this.disposed || callState.cancelled,
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

  private recordLifecycle(event: BridgeLifecycleEvent): void {
    if (this.lifecycleHistory.length >= MAX_LIFECYCLE_HISTORY) {
      this.lifecycleHistory.shift();
    }
    this.lifecycleHistory.push(event);
  }

  private notifyContextChanged(): void {
    const waiters = this.contextWaiters.splice(0, this.contextWaiters.length);
    for (const resolve of waiters) {
      resolve();
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
    if (this.disposed) {
      throw new Error(`Bridge session '${this.sessionId}' is already disposed`);
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
    if (this.disposed || callState.cancelled) {
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
    if (callState.cancelled || this.disposed) {
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
    if (this.disposed) {
      throw new Error(`Bridge session '${this.sessionId}' is already disposed`);
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

  static async open(
    moduleNames: string[],
    abilityContext: common.UIAbilityContext,
    factories: BridgePluginFactory[],
  ): Promise<string> {
    const sessionId = `bridge-${Date.now()}-${BridgeHostRegistry.nextSession++}`;
    const hosts: Map<string, BridgeHost> = new Map();
    try {
      for (const moduleName of moduleNames) {
        const host = new BridgeHost(sessionId, moduleName, abilityContext);
        hosts.set(moduleName, host);
        // Register before installation so a partially-installed plugin is disposed if an
        // ability-context onInstall hook rejects.
        await host.install(factories);
      }
    } catch (error) {
      await BridgeHostRegistry.disposeHosts(hosts);
      throw new Error(String(error));
    }
    BridgeHostRegistry.sessions.set(sessionId, hosts);
    return sessionId;
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

  /**
   * Registers one window's node surface (`windowKey` defaults to `"main"`). Attaching the main
   * window emits `ui-context-ready`, so plugins can mount nodes during `onInstall` without any
   * waiting; sub-window attachments only register state.
   */
  static attachWindow(
    sessionId: string,
    moduleName: string,
    windowKey: string,
    uiContext: UIContext,
    root: FrameNode,
  ): void {
    BridgeHostRegistry.host(sessionId, moduleName).attachWindow(windowKey, uiContext, root);
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
    mainThreadSink: BridgeMainThreadEventSink,
  ): void {
    BridgeHostRegistry.host(sessionId, moduleName).attachEventSink(mainThreadSink);
  }

  static detachEventSink(sessionId: string, moduleName: string): void {
    const host = BridgeHostRegistry.sessions.get(sessionId)?.get(moduleName);
    host?.detachEventSink();
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
    for (const host of values) {
      await host.dispose();
    }
    hosts.clear();
  }
}
