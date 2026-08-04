import { NodeContent } from "@kit.ArkUI";
import common from "@ohos.app.ability.common";
import { UIContext } from "@ohos.arkui.UIContext";
import resourceManager from "@ohos.resourceManager";
import window from "@ohos.window";

export interface ApplicationLifecycle {
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
    pluginVersion: number,
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
    timeoutMs: number,
  ) => Promise<ESObject>;
  bridgeInvokeSync: (
    pluginId: string,
    pluginVersion: number,
    action: string,
    requestTypeName: string,
    responseTypeName: string,
    value: ESObject,
  ) => ESObject;
  bridgeDispatch: () => void;
}

export interface Module {
  init: (context?: AbilityInitContext) => ApplicationLifecycle;
  render: (bindings: BridgeBindings, slot: NodeContent) => void;
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
  kind: BridgeLifecycleKind;
  payload: BridgeLifecyclePayload;
}

/**
 * Context is intentionally ArkTS-only. It is scoped to one native module and one Ability
 * session; Rust gets lifecycle notifications and direct named N-API events, not retained ArkTS
 * object references.
 */
export interface BridgePluginContext {
  pluginId: string;
  moduleName: string;
  sessionId: string;
  abilityContext: common.UIAbilityContext;
  isActive: () => boolean;
  getWindowStage: () => window.WindowStage;
  getUIContext: () => UIContext;
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

interface BridgePluginBase {
  id: string;
  version: number;
  requires?: BridgeContextRequirement[];
}

export interface AsyncBridgePlugin extends BridgePluginBase {
  execution: "async";
  /**
   * Optional: session-scoped context injection, called by BridgeHost right after creation
   * (before onInstall). PluginBase implements it; interface-only plugins may omit it.
   */
  attachContext?: (context: BridgePluginContext) => void;
  onInstall?: (context: BridgePluginContext) => void | Promise<void>;
  onLifecycle?: (event: BridgeLifecycleEvent, context: BridgePluginContext) => void | Promise<void>;
  invokeAsync: (
    action: string,
    request: BridgeTypedValue,
    context: BridgeCallContext,
  ) => Promise<BridgeTypedValue>;
  onDispose?: (context: BridgePluginContext) => void | Promise<void>;
}

export interface MainThreadSyncBridgePlugin extends BridgePluginBase {
  execution: "sync-main-thread";
  /** See [`AsyncBridgePlugin.attachContext`]. */
  attachContext?: (context: BridgePluginContext) => void;
  onInstall?: (context: BridgePluginContext) => void;
  onLifecycle?: (event: BridgeLifecycleEvent, context: BridgePluginContext) => void;
  invokeSync: (
    action: string,
    request: BridgeTypedValue,
    context: BridgeCallContext,
  ) => BridgeTypedValue;
  onDispose?: (context: BridgePluginContext) => void;
}

export type BridgePlugin = AsyncBridgePlugin | MainThreadSyncBridgePlugin;

/**
 * Shared base for plugin implementations. Concrete plugins declare only their identity
 * (`id` / `version` / `requires`) and the invoke method; the execution mode and optional
 * lifecycle hooks come from the mode-specific bases below. The session-scoped context is
 * injected by `BridgeHost` through [`PluginBase.attachContext`] after creation, so plugin
 * constructors never need it.
 */
export abstract class PluginBase {
  abstract readonly id: string;
  abstract readonly version: number;
  abstract readonly requires: BridgeContextRequirement[];
  private context?: BridgePluginContext;

  onInstall(_context: BridgePluginContext): void | Promise<void> {}
  onLifecycle(_event: BridgeLifecycleEvent, _context: BridgePluginContext): void | Promise<void> {}
  onDispose(_context: BridgePluginContext): void | Promise<void> {}

  /**
   * Called once by `BridgeHost` right after creation, before `onInstall`. Subclasses that
   * need the context outside the lifecycle hooks can read it via [`PluginBase.getContext`].
   */
  attachContext(context: BridgePluginContext): void {
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
 * Registration entry for one plugin. Identity (`id` / `version` / `execution` / `requires`)
 * lives only on the plugin instance; the factory is a plain per-session instance creator
 * (plus an optional module filter). Use [`LazyPlugin`] to build one.
 */
export interface BridgePluginFactory {
  /** Optional: restrict this plugin to the listed native module names. */
  modules?: string[];
  /** Creates one plugin instance per native module and Ability session. */
  create: () => BridgePlugin;
}

/**
 * Lazy plugin registration entry: defers instance creation to `BridgeHost.install` (one
 * instance per native module and Ability session) and optionally filters by native module.
 * Identity fields are read from the created instance, so they are never repeated here.
 */
export class LazyPlugin implements BridgePluginFactory {
  readonly modules?: string[];
  private readonly createFn: () => BridgePlugin;

  constructor(create: () => BridgePlugin, modules?: string[]) {
    this.createFn = create;
    this.modules = modules;
  }

  create(): BridgePlugin {
    return this.createFn();
  }
}

/**
 * Eager plugin registration entry: shares one caller-constructed plugin instance across every
 * native module and Ability session, and optionally filters by native module.
 *
 * Use this for plugins that own process-wide global state (for example a singleton native
 * wrapper) where per-session instances would be redundant or lossy. The instance receives
 * `attachContext` for every module/session it is installed into and must tolerate repeated
 * lifecycle and dispose notifications.
 */
export class EagerPlugin implements BridgePluginFactory {
  readonly modules?: string[];
  private readonly instance: BridgePlugin;

  constructor(instance: BridgePlugin, modules?: string[]) {
    this.instance = instance;
    this.modules = modules;
  }

  create(): BridgePlugin {
    return this.instance;
  }
}
