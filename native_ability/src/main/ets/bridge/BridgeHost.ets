import common from "@ohos.app.ability.common";
import { FrameNode } from "@ohos.arkui.node";
import { UIContext } from "@ohos.arkui.UIContext";
import window from "@ohos.window";
import { WindowManager, WindowSizeEventWrap, WindowRectEventWrap } from "../window/WindowManager";
import {
  ApplicationLifecycle,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeEmptyLifecyclePayload,
  BridgeLifecycleEvent,
  BridgeTypedValue,
  AsyncBridgePlugin,
  MainThreadSyncBridgePlugin,
  BridgePlugin,
  BridgePluginContext,
  BridgePluginDeclaration,
  BridgePluginFactory,
  BridgePluginHookContext,
} from "../ability/type";
import { SerialTaskQueue } from "../runtime/SerialTaskQueue";
import { CancellableTaskScope, TaskCancellationSignal } from "../runtime/CancellableTaskScope";
import { FAULT_REGISTRY, FaultInjectionPlugin } from "./FaultInjection";

// Upper bound for per-call timeouts (callers opt in via bridgeInvoke's timeoutMs).
// 5 minutes: interactive flows that put up system UI (e.g. Huawei account login
// panel with SMS verification) can legitimately take minutes; the Rust-side
// default of 15s stays for non-interactive calls.
const MAX_TIMEOUT_MS = 300_000;
const MAX_PAYLOAD_BYTES = 512 * 1024;
const MAX_LIFECYCLE_HISTORY = 16;
const PLUGIN_HOOK_TIMEOUT_MS = 5_000;
const PLUGIN_HOOK_TIMEOUT_PREFIX = "bridge-plugin-hook-timeout:";
const CLAIMED_PLUGIN_INSTANCES: WeakSet<BridgePlugin> = new WeakSet();

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
 * Node state for this module's one attached `DefaultXComponent`.
 */
interface HostComponentState {
  owner: string;
  uiContext?: UIContext;
  rootFrameNode?: FrameNode;
  mountedChildren: Map<string, MountedChild>;
  nodeHandles: Map<number, FrameNode>;
  nodeParents: Map<number, FrameNode>;
  nextNodeHandle: number;
  windowBinding?: ComponentWindowBinding;
}

interface ComponentWindowBinding {
  componentWindow: window.Window;
  onSizeChange: (size: window.Size) => void;
  onRectChange: (options: window.RectChangeOptions) => void;
  onAvoidAreaChange: (options: window.AvoidAreaOptions) => void;
  onKeyboardHeightChange: (height: number) => void;
}

const NODE_SURFACE_PLUGIN_ID = "ohos.node";

/**
 * Built-in session-surface plugin. It is installed by every BridgeHost before business plugins
 * and exposes opaque FrameNode handles to Rust (`create-container` / `append-child` /
 * `mount-into-root` / `dispose`), so an RS-layer node tree can be composed and mounted without
 * FrameNode values crossing the N-API boundary.
 */
class NodeSurfacePlugin implements AsyncBridgePlugin {
  readonly id = NODE_SURFACE_PLUGIN_ID;
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
      this.expectRequest<ESObject>(request, "ohos.node.CreateContainerRequest", action);
      return {
        typeName: "ohos.node.HandleResponse",
        value: new NodeHandleResponse(this.host.createContainerNode()),
      };
    }
    if (action === "append-child") {
      const payload = this.expectRequest<NodeAppendChildPayload>(
        request,
        "ohos.node.AppendChildRequest",
        action,
      );
      this.host.appendChildByHandle(payload.parentHandle, payload.childHandle);
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
      this.host.mountIntoRoot(payload.handle);
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
      this.host.disposeNode(payload.handle);
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

interface NodeAppendChildPayload {
  parentHandle: number;
  childHandle: number;
}

interface NodeMountIntoRootPayload {
  handle: number;
}

interface NodeDisposePayload {
  handle: number;
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

interface PendingComponentAttachment {
  state: HostComponentState;
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
  const order: BridgeContextRequirement[] = ["ability", "window-stage", "ui-context"];
  return requires
    ? requires
        .slice()
        .sort(
          (left: BridgeContextRequirement, right: BridgeContextRequirement): number =>
            order.indexOf(left) - order.indexOf(right),
        )
    : [];
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
  private readonly pluginFactories: BridgePluginFactory[];
  private pluginsConfigured: boolean = false;
  private applicationLifecycle?: ApplicationLifecycle;
  // One native module owns one DefaultXComponent/root tree. Multiple components in an Ability
  // use distinct native modules and therefore distinct BridgeHost instances.
  private component?: HostComponentState;
  private pendingComponent?: PendingComponentAttachment;

  constructor(
    sessionId: string,
    moduleName: string,
    abilityContext: common.UIAbilityContext,
    pluginFactories: BridgePluginFactory[],
  ) {
    this.sessionId = sessionId;
    this.moduleName = moduleName;
    this.abilityContext = abilityContext;
    this.pluginFactories = pluginFactories;
    this.installNodeSurfacePlugin();
    this.installFaultInjectionPlugin();
  }

  /**
   * Matches ArkTS factories against this host's Rust registry after module.init has completed.
   * Native module topology never enters the plugin contract; ID, execution and context are
   * validated structurally before any hook is activated.
   */
  configurePlugins(declarations: BridgePluginDeclaration[]): void {
    if (this.pluginsConfigured) {
      throw new Error(`Bridge plugins are already configured for '${this.moduleName}'`);
    }
    const candidates: Map<string, BridgePlugin> = new Map();
    for (const factory of this.pluginFactories) {
      this.validateFactory(factory);
      const plugin = factory.create();
      this.validatePlugin(plugin);
      if (this.plugins.has(plugin.id)) {
        throw new Error(
          `ArkTS bridge plugin factory '${plugin.id}' conflicts with a built-in plugin`,
        );
      }
      if (candidates.has(plugin.id)) {
        throw new Error(`Duplicate ArkTS bridge plugin factory '${plugin.id}'`);
      }
      candidates.set(plugin.id, plugin);
    }

    const declared: Map<string, boolean> = new Map();
    const selected: BridgePlugin[] = [];
    for (const declaration of declarations) {
      this.validateDeclaration(declaration);
      if (declared.has(declaration.id)) {
        throw new Error(`Rust bridge plugin '${declaration.id}' is declared more than once`);
      }
      declared.set(declaration.id, true);
      const plugin = candidates.get(declaration.id);
      if (plugin === undefined) {
        throw new Error(
          `Rust bridge plugin '${declaration.id}' has no matching ArkTS factory in NativeAbility.bridgePlugins`,
        );
      }
      this.assertPluginDeclaration(plugin, declaration);
      selected.push(plugin);
    }
    for (const plugin of selected) {
      if (CLAIMED_PLUGIN_INSTANCES.has(plugin)) {
        throw new Error(
          `Bridge plugin '${plugin.id}' instance cannot be reused across Ability-session hosts`,
        );
      }
    }
    for (const plugin of selected) {
      CLAIMED_PLUGIN_INSTANCES.add(plugin);
      plugin.attachContext?.(this.pluginContext(plugin.id));
      this.plugins.set(plugin.id, {
        plugin,
        installed: false,
        installAttempted: false,
      });
    }
    this.pluginsConfigured = true;
  }

  attachApplicationLifecycle(lifecycle: ApplicationLifecycle): void {
    this.assertActive();
    if (this.applicationLifecycle !== undefined) {
      throw new Error(`Native module '${this.moduleName}' already attached its Rust lifecycle`);
    }
    this.applicationLifecycle = lifecycle;
  }

  /**
   * Installs the built-in `ohos.node` surface plugin ahead of business plugins. It closes over
   * this host so its actions operate on the module/component root and handle table directly.
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
   * Installs the built-in fault-injection plugin. It is always registered so the
   * "enable"/"set-rule"/"clear" actions are available, but `FAULT_REGISTRY.enabled`
   * defaults to `false` — production builds never call "enable", so `match()` is a
   * no-op (first-line short-circuit) with negligible overhead.
   */
  private installFaultInjectionPlugin(): void {
    const plugin = new FaultInjectionPlugin();
    this.plugins.set(plugin.id, {
      plugin,
      installed: false,
      installAttempted: false,
    });
  }

  /** Registers this native module's single DefaultXComponent root. */
  attachComponent(componentOwner: string, uiContext: UIContext, root: FrameNode): Promise<void> {
    this.assertActive();
    if (!componentOwner) {
      throw new Error("DefaultXComponent render owner must not be empty");
    }
    if (this.component !== undefined || this.pendingComponent !== undefined) {
      throw new Error(
        `Native module '${this.moduleName}' is already bound to a DefaultXComponent; every component must use a distinct native module`,
      );
    }
    const pending: PendingComponentAttachment = {
      state: {
        owner: componentOwner,
        uiContext,
        rootFrameNode: root,
        mountedChildren: new Map(),
        nodeHandles: new Map(),
        nodeParents: new Map(),
        nextNodeHandle: 1,
      },
      cancelled: false,
    };
    this.pendingComponent = pending;

    console.info(`[DBG-AC] attachComponent ENTER mod=${this.moduleName} sess=${this.sessionId} ready=${this.windowStageReady} stageDefined=${this.windowStage !== undefined}`);
    return this.enqueueLifecycle("attach component", async (): Promise<void> => {
      if (this.pendingComponent === pending) {
        this.pendingComponent = undefined;
      }
      if (pending.cancelled) {
        console.info(`[DBG-AC] attachComponent OP cancelled mod=${this.moduleName}`);
        return;
      }
      this.assertActive();
      console.info(`[DBG-AC] attachComponent OP start mod=${this.moduleName} sess=${this.sessionId} ready=${this.windowStageReady} stageDefined=${this.windowStage !== undefined} stageGen=${this.windowStageGeneration} disposed=${this.disposed}`);
      if (!this.windowStageReady) {
        throw new Error(
          `DefaultXComponent cannot attach without an active WindowStage for '${this.moduleName}'`,
        );
      }
      this.attachComponentWindow(pending.state);
      this.component = pending.state;
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
   * Unregisters this module's DefaultXComponent, unmounting keyed children and handle-owned
   * nodes. The root FrameNode itself is disposed by the component.
   */
  async detachComponent(componentOwner: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    const pending = this.pendingComponent;
    if (pending !== undefined) {
      if (pending.state.owner !== componentOwner) {
        return;
      }
      pending.cancelled = true;
      this.pendingComponent = undefined;
      await this.enqueueLifecycle("cancel component attachment", async () => {});
      return;
    }
    const state = this.component;
    if (state === undefined) {
      const windowStageClearPromise = this.windowStageClearPromise;
      if (windowStageClearPromise !== undefined) {
        await windowStageClearPromise;
      }
      return;
    }
    if (state.owner !== componentOwner) {
      return;
    }
    this.component = undefined;
    // Make new calls fail immediately. The queued lifecycle hook still owns the old state and
    // releases it before a later attachment can become ready.
    this.uiContextReady = false;
    this.cancelCallsWithMissingContext();
    this.notifyContextChanged();

    await this.enqueueLifecycle("detach component", async (): Promise<void> => {
      await this.deliverLifecycle({
        kind: "ui-context-destroy",
        payload: new BridgeEmptyLifecyclePayload(),
      });
      this.disposeComponentState(state);
      this.notifyRustLifecycle("ui-context-destroy");
    });
  }

  /** Creates an empty container FrameNode and returns its opaque handle (ohos.node). */
  createContainerNode(): number {
    const state = this.requireComponent();
    const node = new FrameNode(this.requireUiContext(state));
    const handle = state.nextNodeHandle++;
    state.nodeHandles.set(handle, node);
    return handle;
  }

  /** Appends the node of `childHandle` under the node of `parentHandle` (ohos.node). */
  appendChildByHandle(parentHandle: number, childHandle: number): void {
    const state = this.requireComponent();
    const parent = this.lookupNodeHandle(state, parentHandle, "append-child parent");
    const child = this.lookupNodeHandle(state, childHandle, "append-child child");
    this.appendFrameNode(parent, child, `append child handle '${childHandle}'`);
    state.nodeParents.set(childHandle, parent);
  }

  /** Appends a handle-owned node to this module's component root (ohos.node). */
  mountIntoRoot(handle: number): void {
    const state = this.requireComponent();
    const node = this.lookupNodeHandle(state, handle, "mount-into-root");
    const root = this.requireRootFrameNode(state);
    this.appendFrameNode(root, node, `mount handle '${handle}' into module root`);
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
  disposeNode(handle: number): void {
    const state = this.component;
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

  private lookupNodeHandle(state: HostComponentState, handle: number, role: string): FrameNode {
    const node = state.nodeHandles.get(handle);
    if (!node) {
      throw new Error(`Unknown ohos.node handle '${handle}' for ${role}`);
    }
    return node;
  }

  private requireRootFrameNode(state: HostComponentState): FrameNode {
    const root = state.rootFrameNode;
    if (root === undefined) {
      throw new Error(`Bridge root FrameNode is not attached for '${this.moduleName}'`);
    }
    return root;
  }

  private requireUiContext(state: HostComponentState): UIContext {
    const uiContext = state.uiContext;
    if (uiContext === undefined) {
      throw new Error(`Bridge session '${this.sessionId}' has no UIContext`);
    }
    return uiContext;
  }

  private requireComponentWindow(state: HostComponentState): window.Window {
    const boundWindow = state.windowBinding?.componentWindow;
    if (boundWindow !== undefined) {
      return boundWindow;
    }
    const windowName = this.requireUiContext(state).getWindowName();
    if (!windowName) {
      throw new Error(`Native module '${this.moduleName}' has no component Window`);
    }
    try {
      return window.findWindow(windowName);
    } catch (error) {
      throw new Error(
        `Unable to resolve Window '${windowName}' for native module '${this.moduleName}': ${String(error)}`,
      );
    }
  }

  private attachComponentWindow(state: HostComponentState): void {
    // NativeAbility always attaches the Rust lifecycle before page content is loaded. A host with
    // no lifecycle consumer (for example a transport-only unit test) does not need Window event
    // subscriptions; getWindow() still resolves lazily if a plugin explicitly requests it.
    if (this.applicationLifecycle === undefined) {
      return;
    }
    const componentWindow = this.requireComponentWindow(state);
    const onSizeChange = (size: window.Size): void => {
      if (this.component !== state || this.closing || this.disposed) {
        return;
      }
      try {
        // Phase 3 (design.md D2/D3): route through per-window(0) throttle. This is the
        // main-window component window's second windowSizeChange registration (the first
        // is in NativeAbility.ets) — the throttle merges both sources for windowId=0.
        const wrapped: WindowSizeEventWrap = { windowId: 0, width: size.width, height: size.height };
        WindowManager.getInstance().throttledRectDispatch(0, wrapped, (w: object) => {
          if (this.component !== state || this.closing || this.disposed) {
            return;
          }
          this.applicationLifecycle?.windowStageEventCallback.onWindowSizeChange(w);
        }, 'size');
      } catch {}
    };
    const onRectChange = (options: window.RectChangeOptions): void => {
      if (this.component !== state || this.closing || this.disposed) {
        return;
      }
      try {
        // Phase 3 (design.md D2/D3/D5): route through per-window(0) throttle.
        // Deep-copy rect fields (not system object ref) per design.md D5.
        const wrapped: WindowRectEventWrap = {
          windowId: 0,
          reason: options.reason,
          rect: { left: options.rect.left, top: options.rect.top, width: options.rect.width, height: options.rect.height }
        };
        WindowManager.getInstance().throttledRectDispatch(0, wrapped, (w: object) => {
          if (this.component !== state || this.closing || this.disposed) {
            return;
          }
          this.applicationLifecycle?.windowStageEventCallback.onWindowRectChange(w);
        }, 'rect');
      } catch {}
    };
    const onAvoidAreaChange = (options: window.AvoidAreaOptions): void => {
      if (this.component !== state || this.closing || this.disposed) {
        return;
      }
      try {
        this.applicationLifecycle?.windowStageEventCallback.onAvoidAreaChange(options);
      } catch {}
    };
    const onKeyboardHeightChange = (height: number): void => {
      if (this.component !== state || this.closing || this.disposed) {
        return;
      }
      try {
        this.applicationLifecycle?.keyboardEventCallback.onKeyboardHeightChange(height);
      } catch {}
    };
    state.windowBinding = {
      componentWindow,
      onSizeChange,
      onRectChange,
      onAvoidAreaChange,
      onKeyboardHeightChange,
    };
    try {
      componentWindow.on("windowSizeChange", onSizeChange);
    } catch {}
    try {
      componentWindow.on("windowRectChange", onRectChange);
    } catch {}
    try {
      componentWindow.on("avoidAreaChange", onAvoidAreaChange);
    } catch {}
    try {
      componentWindow.on("keyboardHeightChange", onKeyboardHeightChange);
    } catch {}
  }

  private detachComponentWindow(state: HostComponentState): void {
    const binding = state.windowBinding;
    state.windowBinding = undefined;
    if (binding === undefined) {
      return;
    }
    try {
      binding.componentWindow.off("windowSizeChange", binding.onSizeChange);
    } catch {}
    try {
      binding.componentWindow.off("windowRectChange", binding.onRectChange);
    } catch {}
    try {
      binding.componentWindow.off("avoidAreaChange", binding.onAvoidAreaChange);
    } catch {}
    try {
      binding.componentWindow.off("keyboardHeightChange", binding.onKeyboardHeightChange);
    } catch {}
  }

  private requireComponent(): HostComponentState {
    const state = this.component;
    if (state === undefined) {
      throw new Error(`Native module '${this.moduleName}' has no attached DefaultXComponent`);
    }
    return state;
  }

  /** Plugin-context mount: appends an arbitrary FrameNode under this module's component root. */
  appendChild(key: string, node: FrameNode, cleanup?: () => void): void {
    this.assertActive();
    if (!isBridgeIdentifier(key)) {
      throw new Error("Bridge node mount key must contain only letters, digits, '.', '_' or '-'");
    }
    this.removeChild(key);
    try {
      const state = this.requireComponent();
      this.appendFrameNode(
        this.requireRootFrameNode(state),
        node,
        `mount '${key}' into module root`,
      );
      state.mountedChildren.set(key, { node, cleanup });
    } catch (error) {
      try {
        cleanup?.();
      } catch {}
      throw new Error(String(error));
    }
  }

  /** Plugin-context unmount: removes the node mounted under `key` and runs its cleanup. */
  removeChild(key: string): void {
    const state = this.component;
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

  private disposeComponentState(state: HostComponentState): void {
    this.detachComponentWindow(state);
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

  /** Marks the Ability context ready only after the native module and both Rust sinks exist. */
  async activateAbility(event: BridgeLifecycleEvent): Promise<void> {
    this.assertActive();
    if (!this.pluginsConfigured) {
      throw new Error(`Bridge plugins are not configured for '${this.moduleName}'`);
    }
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
    console.info(`[DBG-WS] setWindowStage ENTER mod=${this.moduleName} sess=${this.sessionId} gen=${generation} prevReady=${this.windowStageReady}`);
    await this.enqueueLifecycle("window-stage-create", async (): Promise<void> => {
      this.assertActive();
      console.info(`[DBG-WS] setWindowStage OP start mod=${this.moduleName} sess=${this.sessionId} gen=${generation} windowStageGeneration=${this.windowStageGeneration} prevReady=${this.windowStageReady}`);
      if (generation !== this.windowStageGeneration) {
        console.info(`[DBG-WS] setWindowStage OP SKIP (gen mismatch) mod=${this.moduleName}`);
        return;
      }
      this.windowStage = windowStage;
      this.windowStageReady = true;
      console.info(`[DBG-WS] setWindowStage OP done mod=${this.moduleName} sess=${this.sessionId} ready=true`);
      this.notifyContextChanged();
    });
    console.info(`[DBG-WS] setWindowStage EXIT mod=${this.moduleName} sess=${this.sessionId} ready=${this.windowStageReady}`);
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
    // Claim the component before scheduling cleanup. Otherwise an aboutToDisappear callback in
    // the same event-loop turn can take the state while this operation is waiting on the queue,
    // making window-stage-destroy overtake ui-context-destroy.
    const state = this.component;
    this.component = undefined;
    if (this.uiContextReady) {
      this.uiContextReady = false;
      this.cancelCallsWithMissingContext();
      this.notifyContextChanged();
    }
    const clearPromise = this.enqueueLifecycle("window-stage-destroy", async (): Promise<void> => {
      this.windowStageReady = false;
      if (state !== undefined) {
        await this.deliverLifecycle({
          kind: "ui-context-destroy",
          payload: new BridgeEmptyLifecyclePayload(),
        });
        this.disposeComponentState(state);
        this.notifyRustLifecycle("ui-context-destroy");
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
    const pending = this.pendingComponent;
    if (pending !== undefined) {
      pending.cancelled = true;
      this.pendingComponent = undefined;
    }
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
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
    timeoutMs: number,
  ): Promise<ESObject> {
    const request: BridgeTypedValue = { typeName: requestTypeName, value };
    this.assertWireCall(pluginId, action, request, responseTypeName);
    const entry = this.lookup(pluginId);
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
        // ── Fault injection point A (async path) ──
        // match() returns undefined when disabled (production) or no rule applies.
        const fault = FAULT_REGISTRY.match(pluginId, action);
        if (fault !== undefined) {
          if (fault.kind === "error") {
            throw new Error(`${fault.code}:${fault.message ?? "fault-injected"}`);
          }
          if (fault.kind === "exception") {
            throw new Error(fault.message ?? "fault-injected exception");
          }
          if (fault.kind === "delay") {
            await new Promise<void>((r) => setTimeout(r, fault.ms ?? 0));
            // delay falls through to normal invokeAsync
          }
          if (fault.kind === "timeout") {
            // P1 audit fix: throw instead of returning a pending Promise.
            // A pending Promise would leak callState — removeActiveCall is bound
            // in operation's .finally, which never settles. Throwing causes
            // operation reject → .finally runs → cleanup proceeds normally.
            throw new Error(
              `Bridge call '${pluginId}.${action}' timed out after injected timeout`,
            );
          }
        }
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
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ): ESObject {
    const request: BridgeTypedValue = { typeName: requestTypeName, value };
    this.assertWireCall(pluginId, action, request, responseTypeName);
    const entry = this.lookup(pluginId);
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
    // ── Fault injection point B (sync path) ──
    // Sync path only supports error/exception — delay/timeout would block the
    // NAPI callback thread. match() returns undefined when disabled or no rule.
    const syncFault = FAULT_REGISTRY.match(pluginId, action);
    if (syncFault !== undefined) {
      if (syncFault.kind === "error") {
        throw new Error(`${syncFault.code}:${syncFault.message ?? "fault-injected"}`);
      }
      if (syncFault.kind === "exception") {
        throw new Error(syncFault.message ?? "fault-injected exception");
      }
    }
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
        "Main-thread event sink is unavailable because the native module did not attach its Rust bridge export",
      );
    }
    const entry = this.plugins.get(pluginId);
    if (entry?.hookError !== undefined) {
      throw new Error(entry.hookError);
    }
    return sink(pluginId, event, requestTypeName, responseTypeName, value);
  }

  /** Returns no response when this host/plugin is outside an active Ability session. */
  invokeNativeSyncIfActive(
    pluginId: string,
    event: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ): ESObject | undefined {
    if (!this.abilityReady || this.closing || this.disposed || !this.plugins.has(pluginId)) {
      return undefined;
    }
    return this.invokeNativeSync(pluginId, event, requestTypeName, responseTypeName, value);
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
      this.applicationLifecycle = undefined;
      const pending = this.pendingComponent;
      if (pending !== undefined) {
        pending.cancelled = true;
      }
      this.pendingComponent = undefined;
      // Release keyed mounts first, then handle-owned nodes. The root FrameNode itself is owned
      // and disposed by this module's DefaultXComponent.
      const state = this.component;
      if (state !== undefined) {
        this.disposeComponentState(state);
      }
      this.component = undefined;
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
    return {
      pluginId,
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
      getWindow: (): window.Window => this.requireComponentWindow(this.requireComponent()),
      getUIContext: (): UIContext => this.requireUiContext(this.requireComponent()),
      getRootFrameNode: (): FrameNode => this.requireRootFrameNode(this.requireComponent()),
      appendChild: (key: string, node: FrameNode, cleanup?: () => void): void =>
        this.appendChild(key, node, cleanup),
      removeChild: (key: string): void => this.removeChild(key),
      getFrameNode: (handle: number): FrameNode =>
        this.lookupNodeHandle(this.requireComponent(), handle, "context"),
      invokeNativeSync: (
        event: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject =>
        this.invokeNativeSync(pluginId, event, requestTypeName, responseTypeName, value),
      invokeNativeSyncProcessWide: (
        event: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject[] =>
        BridgeHostRegistry.invokeNativeSyncProcessWide(
          pluginId,
          event,
          requestTypeName,
          responseTypeName,
          value,
        ),
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
      getWindow: (): window.Window => context.getWindow(),
      getUIContext: (): UIContext => context.getUIContext(),
      getRootFrameNode: (): FrameNode => context.getRootFrameNode(),
      appendChild: (key: string, node: FrameNode, cleanup?: () => void): void =>
        context.appendChild(key, node, cleanup),
      removeChild: (key: string): void => context.removeChild(key),
      getFrameNode: (handle: number): FrameNode => context.getFrameNode(handle),
      invokeNativeSync: (
        event: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject =>
        this.invokeNativeSync(pluginId, event, requestTypeName, responseTypeName, value),
      invokeNativeSyncProcessWide: (
        event: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject[] =>
        context.invokeNativeSyncProcessWide(event, requestTypeName, responseTypeName, value),
    };
  }

  private pluginHookContext(
    pluginId: string,
    signal: TaskCancellationSignal,
  ): BridgePluginHookContext {
    const context = this.pluginContext(pluginId);
    return {
      pluginId,
      sessionId: this.sessionId,
      abilityContext: this.abilityContext,
      isActive: (): boolean => context.isActive() && !signal.isCancelled(),
      isCancelled: (): boolean => signal.isCancelled() || this.disposed,
      onCancel: (listener: () => void): (() => void) => signal.onCancel(listener),
      getWindowStage: (): window.WindowStage => context.getWindowStage(),
      getWindow: (): window.Window => context.getWindow(),
      getUIContext: (): UIContext => context.getUIContext(),
      getRootFrameNode: (): FrameNode => context.getRootFrameNode(),
      appendChild: (key: string, node: FrameNode, cleanup?: () => void): void =>
        context.appendChild(key, node, cleanup),
      removeChild: (key: string): void => context.removeChild(key),
      getFrameNode: (handle: number): FrameNode => context.getFrameNode(handle),
      invokeNativeSync: (
        event: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject =>
        this.invokeNativeSync(pluginId, event, requestTypeName, responseTypeName, value),
      invokeNativeSyncProcessWide: (
        event: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject[] =>
        context.invokeNativeSyncProcessWide(event, requestTypeName, responseTypeName, value),
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
          recorded.kind === "window-stage-event",
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

  private lookup(pluginId: string): HostedPlugin {
    this.assertActive();
    const entry = this.plugins.get(pluginId);
    if (!entry) {
      throw new Error(`Bridge plugin '${pluginId}' is not installed for '${this.moduleName}'`);
    }
    if (entry.hookError !== undefined) {
      throw new Error(entry.hookError);
    }
    return entry;
  }

  private assertWireCall(
    pluginId: string,
    action: string,
    request: BridgeTypedValue,
    responseTypeName: string,
  ): void {
    this.assertActive();
    if (!isBridgeIdentifier(pluginId) || !isBridgeIdentifier(action)) {
      throw new Error("Invalid bridge plugin id or action");
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
    // The size cap only applies to BARE top-level string/Uint8Array values.
    // Object payloads are deliberately exempt: actions like capture-webview return
    // a multi-hundred-KB base64 wrapped in an object ({ pngBase64, width, height }),
    // and the Rust side applies no equivalent cap.
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
    if (!isBridgeIdentifier(plugin.id)) {
      throw new Error(`Invalid bridge plugin declaration for module ${this.moduleName}`);
    }
    const requirements = normalizedRequirements(plugin.requires);
    for (let index: number = 0; index < requirements.length; index++) {
      const requirement = requirements[index];
      if (
        requirement !== "ability" &&
        requirement !== "window-stage" &&
        requirement !== "ui-context"
      ) {
        throw new Error(`Invalid context requirement '${requirement}' for '${plugin.id}'`);
      }
      if (requirements.indexOf(requirement) !== index) {
        throw new Error(`Duplicate context requirement '${requirement}' for '${plugin.id}'`);
      }
    }
  }

  private validateDeclaration(declaration: BridgePluginDeclaration): void {
    if (
      !isBridgeIdentifier(declaration.id) ||
      (declaration.execution !== "async" && declaration.execution !== "sync-main-thread") ||
      !Array.isArray(declaration.requires)
    ) {
      throw new Error(`Invalid Rust bridge plugin declaration for '${this.moduleName}'`);
    }
    for (let index: number = 0; index < declaration.requires.length; index++) {
      const requirement = declaration.requires[index];
      if (
        requirement !== "ability" &&
        requirement !== "window-stage" &&
        requirement !== "ui-context"
      ) {
        throw new Error(`Invalid context requirement '${requirement}' for '${declaration.id}'`);
      }
      if (declaration.requires.indexOf(requirement) !== index) {
        throw new Error(`Duplicate context requirement '${requirement}' for '${declaration.id}'`);
      }
    }
  }

  private assertPluginDeclaration(
    plugin: BridgePlugin,
    declaration: BridgePluginDeclaration,
  ): void {
    if (plugin.execution !== declaration.execution) {
      throw new Error(
        `Bridge plugin '${plugin.id}' execution mismatch: Rust=${declaration.execution}, ArkTS=${plugin.execution}`,
      );
    }
    const arktsRequirements = normalizedRequirements(plugin.requires);
    const rustRequirements = normalizedRequirements(declaration.requires);
    if (
      arktsRequirements.length !== rustRequirements.length ||
      arktsRequirements.some(
        (requirement: BridgeContextRequirement, index: number): boolean =>
          requirement !== rustRequirements[index],
      )
    ) {
      throw new Error(
        `Bridge plugin '${plugin.id}' context mismatch: Rust=${rustRequirements.join(",")}, ArkTS=${arktsRequirements.join(",")}`,
      );
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
  /** One loaded native module may belong to only one active Ability session. */
  private static readonly moduleOwners: Map<string, string> = new Map();
  private static nextSession: number = 1;

  static prepare(
    moduleNames: string[],
    abilityContext: common.UIAbilityContext,
    factories: BridgePluginFactory[],
  ): string {
    const sessionId = `bridge-${Date.now()}-${BridgeHostRegistry.nextSession++}`;
    const hosts: Map<string, BridgeHost> = new Map();
    if (moduleNames.length === 0) {
      throw new Error("NativeAbility must declare at least one native module");
    }
    const requestedModules: Map<string, boolean> = new Map();
    for (const moduleName of moduleNames) {
      if (!isBridgeIdentifier(moduleName)) {
        throw new Error(`Invalid native module name '${moduleName}'`);
      }
      if (requestedModules.has(moduleName)) {
        throw new Error(`Native module '${moduleName}' is declared more than once for one Ability`);
      }
      requestedModules.set(moduleName, true);
      const owner = BridgeHostRegistry.moduleOwners.get(moduleName);
      if (owner !== undefined) {
        throw new Error(
          `Native module '${moduleName}' already belongs to active Ability session '${owner}'; use a distinct native module for another Ability`,
        );
      }
    }
    try {
      for (const moduleName of moduleNames) {
        const host = new BridgeHost(sessionId, moduleName, abilityContext, factories);
        hosts.set(moduleName, host);
      }
    } catch (error) {
      throw new Error(String(error));
    }
    BridgeHostRegistry.sessions.set(sessionId, hosts);
    for (const moduleName of moduleNames) {
      BridgeHostRegistry.moduleOwners.set(moduleName, sessionId);
    }
    return sessionId;
  }

  static async activateAbility(
    sessionId: string,
    moduleName: string,
    event: BridgeLifecycleEvent,
  ): Promise<void> {
    await BridgeHostRegistry.host(sessionId, moduleName).activateAbility(event);
  }

  static configurePlugins(
    sessionId: string,
    moduleName: string,
    declarations: BridgePluginDeclaration[],
  ): void {
    BridgeHostRegistry.host(sessionId, moduleName).configurePlugins(declarations);
  }

  static attachApplicationLifecycle(
    sessionId: string,
    moduleName: string,
    lifecycle: ApplicationLifecycle,
  ): void {
    BridgeHostRegistry.host(sessionId, moduleName).attachApplicationLifecycle(lifecycle);
  }

  static async invokeAsync(
    sessionId: string,
    moduleName: string,
    pluginId: string,
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
    timeoutMs: number,
  ): Promise<ESObject> {
    return await BridgeHostRegistry.host(sessionId, moduleName).invokeAsync(
      pluginId,
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
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ): ESObject {
    return BridgeHostRegistry.host(sessionId, moduleName).invokeSync(
      pluginId,
      action,
      requestTypeName,
      responseTypeName,
      value,
    );
  }

  /**
   * Broadcasts one named direct event to every active native module that registered `pluginId`.
   * This is intentionally process-wide for platform resources whose initialization is global.
   */
  static invokeNativeSyncProcessWide(
    pluginId: string,
    event: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ): ESObject[] {
    const responses: ESObject[] = [];
    for (const hosts of BridgeHostRegistry.sessions.values()) {
      for (const host of hosts.values()) {
        const response: ESObject | undefined = host.invokeNativeSyncIfActive(
          pluginId,
          event,
          requestTypeName,
          responseTypeName,
          value,
        );
        if (response !== undefined) {
          responses.push(response);
        }
      }
    }
    return responses;
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

  /** Binds the module to its one DefaultXComponent/root tree. */
  static async attachComponent(
    sessionId: string,
    moduleName: string,
    componentOwner: string,
    uiContext: UIContext,
    root: FrameNode,
  ): Promise<void> {
    await BridgeHostRegistry.host(sessionId, moduleName).attachComponent(
      componentOwner,
      uiContext,
      root,
    );
  }

  /** Unbinds the module's component. The root node itself is disposed by its owner. */
  static async detachComponent(
    sessionId: string,
    moduleName: string,
    componentOwner: string,
  ): Promise<void> {
    const host = BridgeHostRegistry.sessions.get(sessionId)?.get(moduleName);
    await host?.detachComponent(componentOwner);
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
    try {
      await BridgeHostRegistry.disposeHosts(hosts);
    } finally {
      for (const moduleName of hosts.keys()) {
        if (BridgeHostRegistry.moduleOwners.get(moduleName) === sessionId) {
          BridgeHostRegistry.moduleOwners.delete(moduleName);
        }
      }
      hosts.clear();
    }
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
  }
}
