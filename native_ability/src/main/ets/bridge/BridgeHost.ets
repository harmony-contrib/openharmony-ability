import common from "@ohos.app.ability.common";
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
  private uiContext?: UIContext;
  private disposed: boolean = false;
  private readonly sessionId: string;
  private readonly moduleName: string;
  private readonly abilityContext: common.UIAbilityContext;

  constructor(sessionId: string, moduleName: string, abilityContext: common.UIAbilityContext) {
    this.sessionId = sessionId;
    this.moduleName = moduleName;
    this.abilityContext = abilityContext;
  }

  async install(factories: BridgePluginFactory[]): Promise<void> {
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
    if (this.uiContext !== undefined) {
      await this.emitLifecycle({
        kind: "ui-context-destroy",
        payload: new BridgeEmptyLifecyclePayload(),
      });
      this.uiContext = undefined;
    }
    await this.emitLifecycle({
      kind: "window-stage-destroy",
      payload: new BridgeEmptyLifecyclePayload(),
    });
    this.windowStage = undefined;
  }

  async setUiContext(uiContext: UIContext): Promise<void> {
    this.assertActive();
    this.uiContext = uiContext;
    this.notifyContextChanged();
    await this.emitLifecycle({
      kind: "ui-context-ready",
      payload: new BridgeEmptyLifecyclePayload(),
    });
  }

  async clearUiContext(): Promise<void> {
    if (this.disposed || this.uiContext === undefined) {
      return;
    }
    await this.emitLifecycle({
      kind: "ui-context-destroy",
      payload: new BridgeEmptyLifecyclePayload(),
    });
    this.uiContext = undefined;
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
      if (requirement === "ui-context" && this.uiContext === undefined) {
        missing.push(requirement);
      }
    }
    return missing;
  }

  private pluginContext(pluginId: string): BridgePluginContext {
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
      getUIContext: (): UIContext => {
        if (this.uiContext === undefined) {
          throw new Error(`Bridge plugin '${pluginId}' requires a UIContext that is not ready`);
        }
        return this.uiContext;
      },
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
      getWindowStage: (): window.WindowStage => this.pluginContext(pluginId).getWindowStage(),
      getUIContext: (): UIContext => this.pluginContext(pluginId).getUIContext(),
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

  static async setUiContext(
    sessionId: string,
    moduleName: string,
    uiContext: UIContext,
  ): Promise<void> {
    await BridgeHostRegistry.host(sessionId, moduleName).setUiContext(uiContext);
  }

  static async clearUiContext(sessionId: string, moduleName: string): Promise<void> {
    await BridgeHostRegistry.host(sessionId, moduleName).clearUiContext();
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
