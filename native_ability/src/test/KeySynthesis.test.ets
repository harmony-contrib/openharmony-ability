// Key-synthesis guard tests: the dispatchKeyEvent try/catch must contain the
// SYNCHRONOUS BusinessError 17100001 that an unbound WebviewController raises
// from runJavaScript (the JSCrash signature of 2026-10-21 / 2026-10-30), prune
// the stale registry entry for that code only, and leave the healthy dispatch
// path untouched. NOTE: this module's LocalUnit target currently cannot run at
// all (pre-existing compile errors: UI-syntax files in src/main/ets are not
// supported by the local-test compiler), so these cases are the durable
// encoding of assertions that were verified at authoring time by executing the
// transpiled production module in a throwaway harness — including mutation
// runs (guard removed / pruning removed) that both went red.
//
// Device shape note: webview NAPI raises the code as a C string, so err.code
// is "17100001" (string) on a real device while every pre-existing fake used a
// numeric code — that mismatch is exactly why the suite stayed green while the
// device never pruned (same-key double press: one warn per press, zero
// controllerAttached). The string-code case below pins the Number()
// normalization; its mutation arm (bare `=== 17100001`) goes red.
import { describe, it, expect } from "@ohos/hypium";
import web_webview from "@ohos.web.webview";
import {
  hasKeySynthesisController,
  notifyKeySynthesisController,
  synthesizeDomKeyEvent,
  unregisterKeySynthesisController,
} from "../main/ets/helper/key_synthesis";

// Test-private window ids (never 0 = primary, never MAIN_WINDOW_ID) so the
// module-level key_synthesis registry state of the runtime suite is untouched.
const DEAD_BINDING_WINDOW_ID = 900001;
const LIVE_BINDING_WINDOW_ID = 900002;
const HEALTHY_WINDOW_ID = 900003;
const STRING_CODE_WINDOW_ID = 900004;
const ENTER_KEYCODE = 2054; // SPECIAL_KEYS "Enter"

/** Error thrown by the fakes: a real Error subclass instance carrying the
 * BusinessError-shaped `code` the dispatch guard reads
 * ((err as BusinessError).code). ArkTS forbids throwing interface-typed or
 * arbitrary values (arkts-limited-throw), so the fake error must be an Error
 * instance, not a BusinessError object literal. `code` is `number | string`
 * because BOTH shapes occur: framework-raised BusinessErrors carry a numeric
 * code, while webview NAPI errors raised via napi_throw_error carry the code
 * as a C string (device-verified: err.code === "17100001"). */
class FakeBusinessError extends Error {
  code: number | string;
  constructor(code: number | string, message: string) {
    super(message);
    this.code = code;
    this.name = "BusinessError";
  }
}

/** Fake controller whose runJavaScript throws synchronously with 17100001 —
 * models the stale registry entry left behind when the main-window webview is
 * destroyed without a matching unregister (the JSCrash trigger state). */
class UnboundControllerFake {
  runCallCount: number = 0;
  runJavaScript(_script: string): Promise<string> {
    this.runCallCount += 1;
    throw new FakeBusinessError(
      17100001,
      "Init error. The WebviewController must be associated with a Web component",
    );
  }
}

/** Fake controller whose runJavaScript throws synchronously with the DEVICE
 * shape of the unbound error: code is the string "17100001" (napi_throw_error
 * passes the code as a C string). Without the guard's Number() normalization
 * the stale entry would never be pruned and every subsequent key press would
 * re-warn against the dead controller (device evidence: same-key double press
 * logs one warn per press, zero controllerAttached in between). */
class StringCodeUnboundControllerFake {
  runCallCount: number = 0;
  runJavaScript(_script: string): Promise<string> {
    this.runCallCount += 1;
    throw new FakeBusinessError(
      "17100001",
      "Init error. The WebviewController must be associated with a Web component",
    );
  }
}

/** Fake controller whose runJavaScript throws synchronously with a NON-binding
 * error (generic engine/script failure). The registry entry must survive this:
 * only 17100001 proves the Web binding is lost. */
class ScriptErrorControllerFake {
  runCallCount: number = 0;
  runJavaScript(_script: string): Promise<string> {
    this.runCallCount += 1;
    throw new FakeBusinessError(1000, "script evaluation failed");
  }
}

/** Healthy fake: runJavaScript resolves (success path). */
class HealthyControllerFake {
  runCallCount: number = 0;
  runJavaScript(_script: string): Promise<string> {
    this.runCallCount += 1;
    return Promise.resolve("ok");
  }
}

/** Minimal event shape the dispatcher reads (keyCode/type/repeat). Declared
 * locally so the object literal satisfies arkts-no-untyped-obj-literals; the
 * cast to the ambient KeyEvent hops through `object` because ArkTS rejects a
 * direct FakeKeyEvent->KeyEvent assertion (partial property coverage). */
interface FakeKeyEvent {
  keyCode: number;
  type: KeyType;
  repeat: boolean;
}

function fakeKey(type: KeyType, keyCode: number): KeyEvent {
  const event: FakeKeyEvent = { keyCode: keyCode, type: type, repeat: false };
  return event as object as KeyEvent;
}

export default function keySynthesisTest() {
  describe("keySynthesis", () => {
    it("unboundControllerSyncThrowIsContainedAndPrunesRegistryEntry", 0, () => {
      const probe = new UnboundControllerFake();
      notifyKeySynthesisController(
        DEAD_BINDING_WINDOW_ID,
        probe as object as web_webview.WebviewController,
      );
      expect(hasKeySynthesisController(DEAD_BINDING_WINDOW_ID)).assertTrue();

      // Mutation arm: WITHOUT the 17100001 guard this call throws
      // synchronously, the exception escapes into this test body and the test
      // goes red. Deliberately NOT wrapped in try/catch — a catch here would
      // swallow the guard regression (blind-wrapper rule).
      synthesizeDomKeyEvent(fakeKey(KeyType.Down, ENTER_KEYCODE), DEAD_BINDING_WINDOW_ID);

      // (a) exception contained; (b) dispatchKeyEvent returned false, so the
      // runJavaScript attempt happened exactly once.
      expect(probe.runCallCount).assertEqual(1);
      // (c) stale entry pruned so later keys skip the dead controller.
      expect(hasKeySynthesisController(DEAD_BINDING_WINDOW_ID)).assertFalse();

      // (b) observed end-to-end: dispatchedKeys must NOT have grown from the
      // failed Down. Re-attach a healthy controller and release the key — the
      // Up must not emit a keyup into the page (no orphan keyup pairing).
      const healthy = new HealthyControllerFake();
      notifyKeySynthesisController(
        DEAD_BINDING_WINDOW_ID,
        healthy as object as web_webview.WebviewController,
      );
      synthesizeDomKeyEvent(fakeKey(KeyType.Up, ENTER_KEYCODE), DEAD_BINDING_WINDOW_ID);
      expect(healthy.runCallCount).assertEqual(0);

      unregisterKeySynthesisController(DEAD_BINDING_WINDOW_ID);
      expect(hasKeySynthesisController(DEAD_BINDING_WINDOW_ID)).assertFalse();
    });
    it("transientSyncErrorDropsEventButKeepsRegistryEntry", 0, () => {
      const probe = new ScriptErrorControllerFake();
      notifyKeySynthesisController(
        LIVE_BINDING_WINDOW_ID,
        probe as object as web_webview.WebviewController,
      );
      expect(hasKeySynthesisController(LIVE_BINDING_WINDOW_ID)).assertTrue();

      synthesizeDomKeyEvent(fakeKey(KeyType.Down, ENTER_KEYCODE), LIVE_BINDING_WINDOW_ID);
      expect(probe.runCallCount).assertEqual(1);
      // Non-17100001: the binding is not proven lost, so the entry stays.
      expect(hasKeySynthesisController(LIVE_BINDING_WINDOW_ID)).assertTrue();

      // Entry retained means a repeat Down for the held key attempts dispatch
      // again — transient errors never strand the window's key stream.
      synthesizeDomKeyEvent(fakeKey(KeyType.Down, ENTER_KEYCODE), LIVE_BINDING_WINDOW_ID);
      expect(probe.runCallCount).assertEqual(2);

      // Failed dispatch must not register the key as dispatched, so the Up
      // emits no keyup.
      synthesizeDomKeyEvent(fakeKey(KeyType.Up, ENTER_KEYCODE), LIVE_BINDING_WINDOW_ID);
      expect(probe.runCallCount).assertEqual(2);

      unregisterKeySynthesisController(LIVE_BINDING_WINDOW_ID);
      expect(hasKeySynthesisController(LIVE_BINDING_WINDOW_ID)).assertFalse();
    });
    it("stringCodeSyncThrowPrunesRegistryEntryToo", 0, () => {
      const probe = new StringCodeUnboundControllerFake();
      notifyKeySynthesisController(
        STRING_CODE_WINDOW_ID,
        probe as object as web_webview.WebviewController,
      );
      expect(hasKeySynthesisController(STRING_CODE_WINDOW_ID)).assertTrue();

      // Deliberately NOT wrapped in try/catch (blind-wrapper rule). The
      // mutation arm "normalization dropped (bare === 17100001)" keeps the
      // throw contained but leaves the stale entry registered, so the
      // assertFalse below goes red; the numeric-code sibling above stays green
      // under the same mutation — exactly the UT-green/device-red split.
      synthesizeDomKeyEvent(fakeKey(KeyType.Down, ENTER_KEYCODE), STRING_CODE_WINDOW_ID);

      // (a) exception contained; (b) exactly one runJavaScript attempt.
      expect(probe.runCallCount).assertEqual(1);
      // (c) string "17100001" must prune just like the numeric form.
      expect(hasKeySynthesisController(STRING_CODE_WINDOW_ID)).assertFalse();

      // (d) entry pruned ⇒ the repeat Down for the still-held key takes the
      // `!controller` early-return: no second runJavaScript attempt, no warn.
      synthesizeDomKeyEvent(fakeKey(KeyType.Down, ENTER_KEYCODE), STRING_CODE_WINDOW_ID);
      expect(probe.runCallCount).assertEqual(1);

      // (e) the failed Down never registered the key as dispatched, so the Up
      // emits no keyup either.
      synthesizeDomKeyEvent(fakeKey(KeyType.Up, ENTER_KEYCODE), STRING_CODE_WINDOW_ID);
      expect(probe.runCallCount).assertEqual(1);

      unregisterKeySynthesisController(STRING_CODE_WINDOW_ID);
      expect(hasKeySynthesisController(STRING_CODE_WINDOW_ID)).assertFalse();
    });
    it("healthyControllerStillDispatchesAcrossGuardWrap", 0, () => {
      const probe = new HealthyControllerFake();
      notifyKeySynthesisController(
        HEALTHY_WINDOW_ID,
        probe as object as web_webview.WebviewController,
      );
      synthesizeDomKeyEvent(fakeKey(KeyType.Down, ENTER_KEYCODE), HEALTHY_WINDOW_ID);
      expect(probe.runCallCount).assertEqual(1);
      // Success path still returns true: dispatchedKeys grew, so the Up pairs
      // with a keyup dispatch.
      synthesizeDomKeyEvent(fakeKey(KeyType.Up, ENTER_KEYCODE), HEALTHY_WINDOW_ID);
      expect(probe.runCallCount).assertEqual(2);

      unregisterKeySynthesisController(HEALTHY_WINDOW_ID);
      expect(hasKeySynthesisController(HEALTHY_WINDOW_ID)).assertFalse();
    });
  });
}
