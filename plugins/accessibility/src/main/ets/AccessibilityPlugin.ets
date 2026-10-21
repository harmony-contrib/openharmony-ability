import { accessibility } from "@kit.AccessibilityKit";
import { BusinessError, deviceInfo } from "@kit.BasicServicesKit";
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

interface SendEventRequest {
  announcement?: string | null;
  elementId?: number | null;
}
interface LiveAnnouncement {
  text: string;
  assertive: boolean;
}
interface MotionRequest {
  id: string;
}
class MotionState {
  readonly id: string;
  readonly enabled: boolean;
  constructor(id: string, enabled: boolean) {
    this.id = id;
    this.enabled = enabled;
  }
}

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

interface AccessibilityEventAcknowledgement {
  accepted: boolean;
}

export class AccessibilityPlugin extends AsyncPluginBase {
  readonly id = "ohos.accessibility";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  private screenReaderHandler: ((enabled: boolean) => void) | null = null;
  private motionHandler: ((enabled: boolean) => void) | null = null;
  private motionIds: Set<string> = new Set();
  private motionRevision: number = 0;

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }

    if (action === "observe-reduce-motion" || action === "stop-observing-reduce-motion") {
      expectBridgeRequestType(payload, this.id, action, "ohos.accessibility.MotionRequest");
      const request = payload.value as MotionRequest;
      if (!request || typeof request.id !== "string" || !/^[0-9]{1,20}$/.test(request.id)) {
        throw new Error("Invalid motion observation identity");
      }
      if (action === "stop-observing-reduce-motion") {
        this.motionIds.delete(request.id);
        if (this.motionIds.size === 0) {
          this.removeMotionHandler();
        }
      } else {
        if (deviceInfo.sdkApiVersion < 23) {
          throw new Error("Reduced-motion observation requires API 23");
        }
        if (this.motionHandler === null) {
          const handler = (enabled: boolean): void => {
            this.motionRevision++;
            Array.from(this.motionIds).forEach((id: string) => {
              try {
                this.notifyMotion(id, enabled);
              } catch (error) {
                console.warn(`[Accessibility] motion observation: ${String(error)}`);
              }
            });
          };
          accessibility.onAnimationReduceStateChange(handler);
          this.motionHandler = handler;
        }
        this.motionIds.add(request.id);
        try {
          const revision = this.motionRevision;
          const initial = accessibility.isAnimationReduceEnabledSync();
          // A synchronous platform change during the query has already delivered
          // a newer value. Do not overwrite it with the earlier query snapshot.
          if (revision === this.motionRevision) {
            this.notifyMotion(request.id, initial);
          }
        } catch (error) {
          this.motionIds.delete(request.id);
          if (this.motionIds.size === 0) {
            this.removeMotionHandler();
          }
          throw new Error(`Reduced-motion initial observation failed: ${String(error)}`);
        }
      }
      return { typeName: EVENT_ACKNOWLEDGEMENT_TYPE, value: { accepted: true } };
    }

    if (action === "announce-live") {
      if (deviceInfo.sdkApiVersion < 18) {
        throw new Error("Live announcement requires API 18");
      }
      expectBridgeRequestType(payload, this.id, action, "ohos.accessibility.LiveAnnouncement");
      const request = payload.value as LiveAnnouncement;
      if (!request || typeof request.text !== "string" || typeof request.assertive !== "boolean") {
        throw new Error("Invalid live announcement");
      }
      await accessibility.sendAccessibilityEvent({
        type: request.assertive
          ? "announceForAccessibility"
          : "announceForAccessibilityNotInterrupt",
        bundleName: context.abilityContext.abilityInfo.bundleName,
        triggerAction: "common",
        textAnnouncedForAccessibility: request.text,
      });
      if (!context.isActive()) {
        throw new Error("Live announcement session was closed");
      }
      return { typeName: EVENT_ACKNOWLEDGEMENT_TYPE, value: { accepted: true } };
    }

    if (action === "send-event") {
      expectBridgeRequestType(
        payload,
        "ohos.accessibility",
        action,
        "ohos.accessibility.SendEventRequest",
      );
      if (typeof payload.value !== "object" || payload.value === null) {
        throw new Error("Invalid accessibility event");
      }
      const request = payload.value as SendEventRequest;
      const announces = request.announcement !== undefined && request.announcement !== null;
      const focuses = request.elementId !== undefined && request.elementId !== null;
      if (
        announces === focuses ||
        (announces && typeof request.announcement !== "string") ||
        (focuses &&
          (!Number.isInteger(request.elementId) ||
            request.elementId! < 0 ||
            request.elementId! > 0x7fffffff))
      ) {
        throw new Error("Provide exactly one announcement or nonnegative element ID");
      }
      const event: accessibility.EventInfo = {
        type: announces ? "announceForAccessibility" : "requestFocusForAccessibility",
        bundleName: context.abilityContext.abilityInfo.bundleName,
        triggerAction: "common",
      };
      if (announces) {
        event.textAnnouncedForAccessibility = request.announcement!;
      } else {
        event.elementId = request.elementId!;
      }
      await accessibility.sendAccessibilityEvent(event);
      if (!context.isActive()) {
        throw new Error("Bridge session closed during accessibility event");
      }
      return { typeName: EVENT_ACKNOWLEDGEMENT_TYPE, value: { accepted: true } };
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
      expectBridgeRequestType(
        payload,
        "ohos.accessibility",
        action,
        IS_OPEN_ACCESSIBILITY_REQUEST_TYPE,
      );
      // OHOS claims ohos.permission.ACCESSIBILITY (system_core) is required; whether a
      // third-party read-only call is actually rejected is unresolved — surface whatever
      // BusinessError the system throws instead of swallowing it.
      let enabled = false;
      // isScreenReaderOpenSync is API 18+ while the repo baseline is API 12.
      if (deviceInfo.sdkApiVersion < 18) {
        throw new Error(
          `isScreenReaderOpenSync requires API 18+ (current ${deviceInfo.sdkApiVersion})`,
        );
      }
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
        // isOpenTouchGuide (Promise) deprecated since API 10; the Sync variant
        // is its documented replacement (@since 10).
        enabled = accessibility.isOpenTouchGuideSync();
      } catch (e) {
        const err = e as BusinessError;
        throw new Error(`isOpenTouchGuideSync failed: code=${err.code} msg=${err.message}`);
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
          throw new Error(
            `on(screenReaderStateChange) failed: code=${err.code} msg=${err.message}`,
          );
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
    this.motionIds.clear();
    this.removeMotionHandler();
  }

  private removeMotionHandler(): void {
    const handler = this.motionHandler;
    if (handler !== null) {
      // Keep the exact callback identity available for retry after a failed off.
      accessibility.offAnimationReduceStateChange(handler);
      this.motionHandler = null;
    }
  }

  private notifyMotion(id: string, enabled: boolean): void {
    const context = this.getContext();
    if (!context.isActive()) {
      return;
    }
    const response = context.invokeNativeSync(
      "reduce-motion-changed",
      "ohos.accessibility.MotionState",
      EVENT_ACKNOWLEDGEMENT_TYPE,
      new MotionState(id, enabled) as ESObject,
    ) as AccessibilityEventAcknowledgement;
    if (response?.accepted !== true) {
      throw new Error("Invalid reduced-motion acknowledgement");
    }
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
      ) as AccessibilityEventAcknowledgement;
      if (response?.accepted !== true) {
        throw new Error("Invalid accessibility-state-changed acknowledgement");
      }
    } catch (e) {
      console.error(`[Accessibility] state-changed notification failed: ${String(e)}`);
    }
  }
}
