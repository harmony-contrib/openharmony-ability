import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import test from "node:test";
const source = await readFile(
  new URL("../src/main/ets/AccessibilityPlugin.ets", import.meta.url),
  "utf8",
);
const prefix = `class AsyncPluginBase {} function expectBridgeRequestType(payload, plugin, action, name) { if (payload.typeName !== name) throw new Error("typeName"); }`;
const { AccessibilityPlugin } = await import(
  `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(prefix + source.slice(source.indexOf("const GET_FONT_SCALE_REQUEST_TYPE")))).toString("base64")}`
);
const payload = (id) => ({ typeName: "ohos.accessibility.MotionRequest", value: { id } });
function plugin(events) {
  const owner = new AccessibilityPlugin();
  const context = {
    isActive: () => true,
    abilityContext: { abilityInfo: { bundleName: "demo" } },
    invokeNativeSync: (name, request, response, value) => {
      events.push(value.enabled);
      return { accepted: true };
    },
  };
  owner.getContext = () => context;
  return { owner, context };
}
test("a change delivered during initial query cannot be overwritten by the older snapshot", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 23 };
  let handler;
  globalThis.accessibility = {
    onAnimationReduceStateChange: (value) => {
      handler = value;
    },
    isAnimationReduceEnabledSync: () => {
      handler(true);
      return false;
    },
    offAnimationReduceStateChange: () => {},
  };
  const events = [],
    { owner, context } = plugin(events);
  await owner.invokeAsync("observe-reduce-motion", payload("0"), context);
  assert.deepEqual(events, [true]);
  await owner.invokeAsync("stop-observing-reduce-motion", payload("0"), context);
  handler(false);
  assert.deepEqual(events, [true]);
});
test("identical IDs belong to independent plugin owners and disposal removes only its callback", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 23 };
  const handlers = new Set();
  globalThis.accessibility = {
    onAnimationReduceStateChange: (h) => handlers.add(h),
    isAnimationReduceEnabledSync: () => false,
    offAnimationReduceStateChange: (h) => handlers.delete(h),
  };
  const first = [],
    second = [],
    a = plugin(first),
    b = plugin(second);
  await a.owner.invokeAsync("observe-reduce-motion", payload("0"), a.context);
  await b.owner.invokeAsync("observe-reduce-motion", payload("0"), b.context);
  a.owner.onDispose();
  for (const handler of handlers) handler(true);
  assert.deepEqual(first, [false]);
  assert.deepEqual(second, [false, true]);
  b.owner.onDispose();
  assert.equal(handlers.size, 0);
});
test("unsubscribe failure keeps the callback identity for retry and is not acknowledged", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 23 };
  let fail = true,
    installed;
  globalThis.accessibility = {
    onAnimationReduceStateChange: (h) => {
      installed = h;
    },
    isAnimationReduceEnabledSync: () => false,
    offAnimationReduceStateChange: (h) => {
      assert.equal(h, installed);
      if (fail) throw new Error("platform off failed");
    },
  };
  const state = plugin([]);
  await state.owner.invokeAsync("observe-reduce-motion", payload("0"), state.context);
  await assert.rejects(
    state.owner.invokeAsync("stop-observing-reduce-motion", payload("0"), state.context),
    /off failed/,
  );
  assert.equal(state.owner.motionHandler, installed);
  fail = false;
  state.owner.onDispose();
  assert.equal(state.owner.motionHandler, null);
});
test("API gates and event shape validation happen before platform mutation", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 12 };
  globalThis.accessibility = { sendAccessibilityEvent: () => assert.fail("invalid event sent") };
  const state = plugin([]);
  await assert.rejects(
    state.owner.invokeAsync("observe-reduce-motion", payload("0"), state.context),
    /API 23/,
  );
  await assert.rejects(
    state.owner.invokeAsync(
      "announce-live",
      {
        typeName: "ohos.accessibility.LiveAnnouncement",
        value: { text: "hello", assertive: false },
      },
      state.context,
    ),
    /API 18/,
  );
  for (const value of [{}, { announcement: "hi", elementId: 1 }, { elementId: 0x80000000 }]) {
    await assert.rejects(
      state.owner.invokeAsync(
        "send-event",
        { typeName: "ohos.accessibility.SendEventRequest", value },
        state.context,
      ),
      /exactly one/,
    );
  }
});
