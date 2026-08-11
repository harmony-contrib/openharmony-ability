import { NodeContent } from "@kit.ArkUI";
import common from "@ohos.app.ability.common";
import { FrameNode } from "@ohos.arkui.node";
import { UIContext } from "@ohos.arkui.UIContext";
import resourceManager from "@ohos.resourceManager";
import window from "@ohos.window";

export interface ApplicationLifecycle {
  bridgePlugins: BridgePluginDeclaration[];
  environmentCallback: EnvironmentCallback;
  windowStageEventCallback: WindowStageEventCallback;
  keyboardEventCallback: KeyboardCallback;
}

export interface EnvironmentCallback {
  onConfigurationUpdated: (arg: object) => void;
  onMemoryLevel: (arg: number) => void;
}

export interface KeyboardCallback {
  onKeyboardHeightChange: (height: number) => void;
}

export interface WindowStageEventCallback {
  onWindowStageCreate: () => void;
  onWindowStageDestroy: () => void;
  onAbilityCreate: (arg: string) => void;
  onAbilityDestroy: () => void;
  onAbilitySaveState: () => string;
  onWindowStageEvent: (arg: number) => void;
  onWindowSizeChange: (arg: object) => void;
  onWindowRectChange: (arg: object) => void;
  onAvoidAreaChange: (arg: object) => void;
}

export interface AbilityInitContext {
  basePath?: string;
  prefPath?: string;
  preferredLocales?: string;
  moduleName?: string;
  resourceManager?: resourceManager.ResourceManager;
}

/**
 * A named value exchanged through the N-API bridge. `typeName` is a stable Rust ↔ ArkTS contract
 * (for example `std.string`, `std.bytes`, or `account.LoginToken`); `value` remains the actual
 * N-API value, not a serialization or Base64 envelope.
 */
export interface BridgeTypedValue {
  typeName: string;
  value: ESObject;
}

export interface BridgeBindings {
  bridgeInvoke: (
    pluginId: string,
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
    timeoutMs: number,
  ) => Promise<ESObject>;
  bridgeInvokeSync: (
    pluginId: string,
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ) => ESObject;
  bridgeDispatch: () => void;
}

export interface Module {
  /**
   * Opens this native module's Ability-session bridge before any component is rendered. The
   * owner is unique per Ability session and guards a later session from stale cleanup.
   */
  init: (
    bindings: BridgeBindings,
    bridgeOwner: string,
    context?: AbilityInitContext,
  ) => ApplicationLifecycle;
  /** Releases only the matching Ability-session bridge; stale owners are ignored. */
  disposeBridge: (bridgeOwner: string) => void;
  /**
   * Mounts this native module's one Rust render tree into `slot`. `renderOwner` is unique per
   * appearance and protects a later render from stale cleanup; another concurrently active
   * DefaultXComponent must use a different native module.
   */
  render: (slot: NodeContent, renderOwner: string) => void;
  /** Releases only the render tree owned by `renderOwner`. */
  disposeRender: (renderOwner: string) => void;
  /** Releases the remaining render tree when the WindowStage is torn down. */
  disposeAllRenders: () => void;
  /** Synchronous page-back decision exported by the native module, when it has one. */
  onBackPressIntercept?: () => boolean;
  /** Legacy N-API spelling retained for modules built before camel-case code generation. */
  on_back_press_intercept?: () => boolean;
  /**
   * Synchronous ArkTS platform callback -> Rust plugin decision. The value is a named N-API
   * object and must be returned before the platform callback resumes.
   */
  onBridgeSyncEvent?: (
    pluginId: string,
    event: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ) => ESObject;
  onBridgeLifecycle?: (kind: string) => void;
}

export type BridgePluginExecution = "async" | "sync-main-thread";
export type BridgeContextRequirement = "ability" | "window-stage" | "ui-context";

/** Rust-side scheduling contract exported after one native module configures its registry. */
export interface BridgePluginDeclaration {
  id: string;
  execution: BridgePluginExecution;
  requires: BridgeContextRequirement[];
}
export type BridgeLifecycleKind =
  | "ability-create"
  | "ability-destroy"
  | "window-stage-create"
  | "window-stage-destroy"
  | "window-stage-event"
  | "ui-context-ready"
  | "ui-context-destroy"
  | "configuration-updated"
  | "memory-level";

export class BridgeEmptyLifecyclePayload {}

export class BridgeAbilityCreateLifecyclePayload {
  readonly restoredState: string;

  constructor(restoredState: string) {
    this.restoredState = restoredState;
  }
}

export class BridgeWindowStageEventLifecyclePayload {
  readonly event: number;

  constructor(event: number) {
    this.event = event;
  }
}

export class BridgeMemoryLevelLifecyclePayload {
  readonly level: number;

  constructor(level: number) {
    this.level = level;
  }
}

export type BridgeLifecyclePayload =
  | BridgeEmptyLifecyclePayload
  | BridgeAbilityCreateLifecyclePayload
  | BridgeWindowStageEventLifecyclePayload
  | BridgeMemoryLevelLifecyclePayload;

export interface BridgeLifecycleEvent {
  readonly kind: BridgeLifecycleKind;
  readonly payload: BridgeLifecyclePayload;
}

/**
 * Context is intentionally ArkTS-only and scoped to one Ability-session plugin instance. Native
 * module routing is a BridgeHost implementation detail: plugins operate only on their attached
 * platform context and never branch on a module name.
 *
 * A native module is bound to exactly one `DefaultXComponent` at a time, and every plugin for
 * that module shares the component's root FrameNode. An Ability may host several components by
 * using a distinct native module for each one. There are no named slots or registries: the root
 * exists before
 * `ui-context-ready`, so plugins can mount nodes during `onInstall`. `appendChild`/`removeChild`
 * use a caller-chosen key as the plugin's own cleanup credential; handle-based composition
 * (`getFrameNode`) is the Rust-facing surface of the built-in `ohos.node` plugin.
 */
export interface BridgePluginContext {
  pluginId: string;
  sessionId: string;
  abilityContext: common.UIAbilityContext;
  isActive: () => boolean;
  /** Returns the Ability-level WindowStage. This is not necessarily the component's window. */
  getWindowStage: () => window.WindowStage;
  /** Resolves the actual Window that owns the attached DefaultXComponent. */
  getWindow: () => window.Window;
  getUIContext: () => UIContext;
  /**
   * Returns this module's component root FrameNode, attached before
   * `ui-context-ready`. Plugins mount their own nodes here.
   */
  getRootFrameNode: () => FrameNode;
  /**
   * Appends a FrameNode to this module's component root. `key` must be unique per plugin
   * (normally prefixed by the plugin id) and is the cleanup credential for `removeChild`. An
   * optional `cleanup` runs when
   * the node is removed or the bridge session disposes.
   */
  appendChild: (key: string, node: FrameNode, cleanup?: () => void) => void;
  /** Removes the node previously appended under `key` and runs its cleanup. */
  removeChild: (key: string) => void;
  /**
   * Resolves an opaque node handle issued by the built-in `ohos.node` plugin (for example a
   * container created from Rust) into its ArkTS FrameNode.
   */
  getFrameNode: (handle: number) => FrameNode;
  /**
   * Makes an immediate, named N-API request to the matching Rust plugin. It is valid only while
   * the current ArkTS/N-API callback is active; do not retain the input or result.
   */
  invokeNativeSync: (
    event: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ) => ESObject;
  /**
   * Sends the same named event to every active Rust facade for this process-level capability.
   * This is reserved for genuinely process-global platform transitions (for example ArkWeb
   * engine initialization); ordinary callbacks must use `invokeNativeSync`.
   */
  invokeNativeSyncProcessWide: (
    event: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ) => ESObject[];
}

export interface BridgeCallContext extends BridgePluginContext {
  action: string;
  timeoutMs: number;
  isCancelled: () => boolean;
  /**
   * Registers a listener that is invoked once when this asynchronous call is cancelled (for
   * example because its caller timed out or its Ability session was disposed). The returned
   * function removes the listener. This is the lifecycle signal for waits on ArkUI state; it is
   * deliberately separate from a timer-based readiness heuristic.
   */
  onCancel: (listener: () => void) => () => void;
}

/**
 * A bounded execution scope for one plugin hook. BridgeHost cancels the scope when the session
 * closes or the hook exceeds its watchdog, allowing teardown to continue with the next plugin.
 */
export interface BridgePluginHookContext extends BridgePluginContext {
  isCancelled: () => boolean;
  onCancel: (listener: () => void) => () => void;
}

interface BridgePluginBase {
  id: string;
  requires?: BridgeContextRequirement[];
}

export interface AsyncBridgePlugin extends BridgePluginBase {
  execution: "async";
  /**
   * Optional: session-scoped context injection, called by BridgeHost right after creation
   * (before onInstall). PluginBase implements it; interface-only plugins may omit it.
   */
  attachContext?: (context: BridgePluginContext) => void;
  onInstall?: (context: BridgePluginHookContext) => void | Promise<void>;
  onLifecycle?: (
    event: BridgeLifecycleEvent,
    context: BridgePluginHookContext,
  ) => void | Promise<void>;
  invokeAsync: (
    action: string,
    request: BridgeTypedValue,
    context: BridgeCallContext,
  ) => Promise<BridgeTypedValue>;
  onDispose?: (context: BridgePluginHookContext) => void | Promise<void>;
}

export interface MainThreadSyncBridgePlugin extends BridgePluginBase {
  execution: "sync-main-thread";
  /** See [`AsyncBridgePlugin.attachContext`]. */
  attachContext?: (context: BridgePluginContext) => void;
  onInstall?: (context: BridgePluginHookContext) => void;
  onLifecycle?: (event: BridgeLifecycleEvent, context: BridgePluginHookContext) => void;
  invokeSync: (
    action: string,
    request: BridgeTypedValue,
    context: BridgeCallContext,
  ) => BridgeTypedValue;
  onDispose?: (context: BridgePluginHookContext) => void;
}

export type BridgePlugin = AsyncBridgePlugin | MainThreadSyncBridgePlugin;

/**
 * Shared base for plugin implementations. Concrete plugins declare only their identity
 * (`id` / `requires`) and the invoke method; the execution mode and optional
 * lifecycle hooks come from the mode-specific bases below. The session-scoped context is
 * injected by `BridgeHost` through [`PluginBase.attachContext`] after creation, so plugin
 * constructors never need it.
 */
export abstract class PluginBase {
  abstract readonly id: string;
  abstract readonly requires: BridgeContextRequirement[];
  private context?: BridgePluginContext;

  onInstall(_context: BridgePluginHookContext): void | Promise<void> {}
  onLifecycle(
    _event: BridgeLifecycleEvent,
    _context: BridgePluginHookContext,
  ): void | Promise<void> {}
  onDispose(_context: BridgePluginHookContext): void | Promise<void> {}

  /**
   * Called once by `BridgeHost` right after creation, before `onInstall`. Subclasses that
   * need the context outside the lifecycle hooks can read it via [`PluginBase.getContext`].
   */
  attachContext(context: BridgePluginContext): void {
    if (this.context !== undefined) {
      throw new Error(
        `Bridge plugin '${this.id}' instance cannot be reused across Ability-session hosts`,
      );
    }
    this.context = context;
  }

  protected getContext(): BridgePluginContext {
    const context = this.context;
    if (context === undefined) {
      throw new Error(`Bridge plugin '${this.id}' was used before its context was attached`);
    }
    return context;
  }
}

/** Base class for asynchronous plugins. `execution` is fixed by the base; subclasses never
 * repeat the literal annotation (ArkTS rejects `as const`, so the base owns the annotation). */
export abstract class AsyncPluginBase extends PluginBase implements AsyncBridgePlugin {
  readonly execution: "async" = "async";

  abstract invokeAsync(
    action: string,
    request: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue>;
}

/** Base class for main-thread synchronous plugins. See [`AsyncPluginBase`]. */
export abstract class SyncPluginBase extends PluginBase implements MainThreadSyncBridgePlugin {
  readonly execution: "sync-main-thread" = "sync-main-thread";

  abstract invokeSync(
    action: string,
    request: BridgeTypedValue,
    context: BridgeCallContext,
  ): BridgeTypedValue;
}

/**
 * Registration entry for one plugin. Identity (`id` / `execution` / `requires`) lives only on
 * the plugin instance; the factory is a plain per-host instance creator. BridgeHost matches it
 * automatically against the declarations exported by each Rust registry.
 */
export interface BridgePluginFactory {
  /** Creates a fresh plugin instance for an automatically matched Ability-session host. */
  create: () => BridgePlugin;
}

/**
 * Lazy plugin registration entry. Identity fields are read from the created instance and matched
 * to Rust declarations, so application code never repeats a plugin ID or native module list.
 */
export class LazyPlugin implements BridgePluginFactory {
  private readonly createFn: () => BridgePlugin;

  constructor(create: () => BridgePlugin) {
    this.createFn = create;
  }

  create(): BridgePlugin {
    return this.createFn();
  }
}
