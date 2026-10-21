import {
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeLifecycleEvent,
  BridgePluginHookContext,
  BridgeTypedValue,
  MainThreadSyncBridgePlugin,
} from "@ohos-rs/ability";
import { NativeViews } from "./NativeViews";
import { NativeEditors } from "./NativeEditors";
import deviceInfo from "@ohos.deviceInfo";

/** Standard API-20 editor and native subtree capability. */
export class ArkuiPlugin implements MainThreadSyncBridgePlugin {
  readonly id: string = "ohos.arkui";
  readonly execution: "sync-main-thread" = "sync-main-thread";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];
  private views: NativeViews = new NativeViews();
  private editors: NativeEditors = new NativeEditors();
  invokeSync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): BridgeTypedValue {
    if (!context.isActive()) {
      throw new Error("ArkUI bridge session is no longer active");
    }
    if (deviceInfo.sdkApiVersion < 20) {
      throw new Error("ArkUI editors require API 20");
    }
    if (action === "apply-native-views") {
      return this.views.apply(payload, context);
    }
    if (action === "apply-editors") {
      return this.editors.apply(payload, context);
    }
    throw new Error(`Unsupported ohos.arkui action '${action}'`);
  }
  async onLifecycle(event: BridgeLifecycleEvent, _context: BridgePluginHookContext): Promise<void> {
    if (event.kind === "ui-context-destroy") {
      await this.onDispose(_context);
    }
  }
  onClosing(context: BridgePluginHookContext): void {
    try {
      this.views.dispose(context);
    } finally {
      this.editors.dispose(context);
    }
  }
  async onDispose(context: BridgePluginHookContext): Promise<void> {
    try {
      this.onClosing(context);
    } finally {
      await this.views.settled();
    }
  }
}
