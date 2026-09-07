import { accessibility } from "@kit.AccessibilityKit";
import { BusinessError } from "@kit.BasicServicesKit";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

const GET_FONT_SCALE_REQUEST_TYPE = "ohos.accessibility.GetFontScaleRequest";
const GET_FONT_SCALE_RESPONSE_TYPE = "ohos.accessibility.GetFontScaleResponse";
const IS_OPEN_ACCESSIBILITY_REQUEST_TYPE = "ohos.accessibility.IsOpenAccessibilityRequest";
const IS_OPEN_ACCESSIBILITY_RESPONSE_TYPE = "ohos.accessibility.IsOpenAccessibilityResponse";
const IS_TOUCH_EXPLORE_REQUEST_TYPE = "ohos.accessibility.IsTouchExploreRequest";
const IS_TOUCH_EXPLORE_RESPONSE_TYPE = "ohos.accessibility.IsTouchExploreResponse";
const SUBSCRIBE_REQUEST_TYPE = "ohos.accessibility.SubscribeRequest";
const SUBSCRIBE_RESPONSE_TYPE = "ohos.accessibility.SubscribeResponse";
const UNSUBSCRIBE_REQUEST_TYPE = "ohos.accessibility.UnsubscribeRequest";
const UNSUBSCRIBE_RESPONSE_TYPE = "ohos.accessibility.UnsubscribeResponse";

// Main-thread event pushed to the Rust facade when the screen-reader state changes
// (invokeNativeSync, same transport as WebviewPlugin's notifyNative).
const STATE_CHANGED_EVENT_TYPE = "ohos.accessibility.StateChangedEvent";
const EVENT_ACKNOWLEDGEMENT_TYPE = "ohos.accessibility.EventAcknowledgement";

interface GetFontScaleRequest {}

interface IsOpenAccessibilityRequest {}

interface IsTouchExploreRequest {}

interface SubscribeRequest {}

interface UnsubscribeRequest {}

class GetFontScaleResponse {
  readonly fontScale: number;

  constructor(fontScale: number) {
    this.fontScale = fontScale;
  }
}

class IsOpenAccessibilityResponse {
  readonly enabled: boolean;

  constructor(enabled: boolean) {
    this.enabled = enabled;
  }
}

class IsTouchExploreResponse {
  readonly enabled: boolean;

  constructor(enabled: boolean) {
    this.enabled = enabled;
  }
}

class SubscribeResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class UnsubscribeResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

/** Payload of the `accessibility-state-changed` main-thread event. */
class AccessibilityStateChangedEvent {
  readonly enabled: boolean;

  constructor(enabled: boolean) {
    this.enabled = enabled;
  }
}

export class AccessibilityPlugin extends AsyncPluginBase {
  readonly id = "ohos.accessibility";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  private screenReaderHandler: ((enabled: boolean) => void) | null = null;

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }

    if (action === "get-font-scale") {
      expectBridgeRequestType(payload, "ohos.accessibility", action, GET_FONT_SCALE_REQUEST_TYPE);
      // fontScale requires no permission; config is always present on UIAbilityContext.
      // NOTE: the SDK Configuration property is fontSizeScale — fontScale does not exist.
      const config = context.abilityContext.config;
      if (config === null || config === undefined || typeof config.fontSizeScale !== "number") {
        throw new Error("abilityContext.config.fontSizeScale is unavailable");
      }
      return {
        typeName: GET_FONT_SCALE_RESPONSE_TYPE,
        value: new GetFontScaleResponse(config.fontSizeScale),
      };
    }

    if (action === "is-open-accessibility") {
      expectBridgeRequestType(payload, "ohos.accessibility", action, IS_OPEN_ACCESSIBILITY_REQUEST_TYPE);
      // OHOS claims ohos.permission.ACCESSIBILITY (system_core) is required; whether a
      // third-party read-only call is actually rejected is unresolved — surface whatever
      // BusinessError the system throws instead of swallowing it.
      let enabled = false;
      try {
        enabled = accessibility.isScreenReaderOpenSync();
      } catch (e) {
        const err = e as BusinessError;
        throw new Error(`isScreenReaderOpenSync failed: code=${err.code} msg=${err.message}`);
      }
      return {
        typeName: IS_OPEN_ACCESSIBILITY_RESPONSE_TYPE,
        value: new IsOpenAccessibilityResponse(enabled),
      };
    }

    if (action === "is-touch-explore-enabled") {
      expectBridgeRequestType(payload, "ohos.accessibility", action, IS_TOUCH_EXPLORE_REQUEST_TYPE);
      let enabled = false;
      try {
        enabled = await accessibility.isOpenTouchGuide();
      } catch (e) {
        const err = e as BusinessError;
        throw new Error(`isOpenTouchGuide failed: code=${err.code} msg=${err.message}`);
      }
      return {
        typeName: IS_TOUCH_EXPLORE_RESPONSE_TYPE,
        value: new IsTouchExploreResponse(enabled),
      };
    }

    if (action === "subscribe-state-change") {
      expectBridgeRequestType(payload, "ohos.accessibility", action, SUBSCRIBE_REQUEST_TYPE);
      // Idempotent: re-subscribing without unsubscribe just re-acks.
      if (this.screenReaderHandler === null) {
        const handler = (enabled: boolean): void => {
          this.notifyStateChanged(enabled);
        };
        try {
          accessibility.on("screenReaderStateChange", handler);
        } catch (e) {
          const err = e as BusinessError;
          throw new Error(`on(screenReaderStateChange) failed: code=${err.code} msg=${err.message}`);
        }
        this.screenReaderHandler = handler;
      }
      return {
        typeName: SUBSCRIBE_RESPONSE_TYPE,
        value: new SubscribeResponse(true),
      };
    }

    if (action === "unsubscribe-state-change") {
      expectBridgeRequestType(payload, "ohos.accessibility", action, UNSUBSCRIBE_REQUEST_TYPE);
      this.removeScreenReaderHandler();
      return {
        typeName: UNSUBSCRIBE_RESPONSE_TYPE,
        value: new UnsubscribeResponse(true),
      };
    }

    throw new Error(`Unsupported ohos.accessibility action '${action}'`);
  }

  onDispose(): void {
    // Session teardown: drop the system callback so it never fires into a dead bridge.
    this.removeScreenReaderHandler();
  }

  private removeScreenReaderHandler(): void {
    if (this.screenReaderHandler !== null) {
      try {
        accessibility.off("screenReaderStateChange");
      } catch {
        // Best-effort: the system may already have detached the callback.
      }
      this.screenReaderHandler = null;
    }
  }

  /**
   * Pushes a screen-reader state change to the Rust facade. Best-effort: if the
   * bridge session is already disposed, drop the event silently (the subscription
   * itself is informational).
   */
  private notifyStateChanged(enabled: boolean): void {
    try {
      const context = this.getContext();
      const response = context.invokeNativeSync(
        "accessibility-state-changed",
        STATE_CHANGED_EVENT_TYPE,
        EVENT_ACKNOWLEDGEMENT_TYPE,
        new AccessibilityStateChangedEvent(enabled) as ESObject,
      ) as ESObject;
      if (response === null || typeof response !== "object") {
        throw new Error("Invalid accessibility-state-changed acknowledgement");
      }
    } catch (e) {
      console.error(`[Accessibility] state-changed notification failed: ${String(e)}`);
    }
  }
}
