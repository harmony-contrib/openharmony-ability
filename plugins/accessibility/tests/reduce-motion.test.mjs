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
function plugin(events, ids = new Set(), screenReader = false) {
  const owner = new AccessibilityPlugin();
  const context = {
    isActive: () => true,
    abilityContext: { abilityInfo: { bundleName: "demo" } },
    invokeNativeSync: (name, request, response, value) => {
      if (name === "subscriptions-ready") {
        assert.equal(request, "ohos.accessibility.SubscriptionsRequest");
        assert.equal(response, "ohos.accessibility.Subscriptions");
        return { screenReader, motionIds: Array.from(ids) };
      }
      assert.equal(name, "reduce-motion-changed");
      assert.equal(request, "ohos.accessibility.MotionState");
      assert.equal(response, "ohos.accessibility.EventAcknowledgement");
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

test("ready and context changes reconcile live routes without workers or queued replay", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 23 };
  const handlers = new Set();
  let installs = 0;
  globalThis.accessibility = {
    onAnimationReduceStateChange: (handler) => {
      installs++;
      handlers.add(handler);
    },
    isAnimationReduceEnabledSync: () => false,
    offAnimationReduceStateChange: (handler) => handlers.delete(handler),
  };
  const events = [];
  const ids = new Set(["0", "1"]);
  const first = plugin(events, ids);
  first.owner.onInstall(first.context);
  assert.equal(handlers.size, 1);
  assert.deepEqual(events, [false, false]);
  first.owner.onDispose();
  assert.equal(handlers.size, 0);

  ids.delete("0"); // Rust Drop removes the route before a replacement session exists.
  const second = plugin(events, ids);
  second.owner.onInstall(second.context);
  assert.deepEqual(events, [false, false, false]);
  second.owner.onLifecycle({ kind: "configuration-updated" }, second.context);
  assert.equal(installs, 2); // No second system listener on a context update.
  ids.clear();
  second.owner.onLifecycle({ kind: "configuration-updated" }, second.context);
  assert.equal(handlers.size, 0);
  second.owner.onDispose();
});

test("empty ready snapshot needs neither API 23 nor any system listener", () => {
  globalThis.deviceInfo = { sdkApiVersion: 12 };
  globalThis.accessibility = {};
  const { owner, context } = plugin([]);
  owner.onInstall(context);
  owner.onDispose();
});

test("multiple routes share one listener; retired Rust routes prune it on the next event", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 23 };
  let handler;
  let installs = 0;
  let removals = 0;
  globalThis.accessibility = {
    onAnimationReduceStateChange: (value) => {
      installs++;
      handler = value;
    },
    isAnimationReduceEnabledSync: () => false,
    offAnimationReduceStateChange: (value) => {
      assert.equal(value, handler);
      removals++;
    },
  };
  const ids = new Set(["0", "1"]);
  const events = [];
  const state = plugin(events);
  state.context.invokeNativeSync = (_event, _request, _response, value) => {
    if (ids.has(value.id)) events.push([value.id, value.enabled]);
    return { accepted: ids.has(value.id) };
  };
  await state.owner.invokeAsync("observe-reduce-motion", payload("0"), state.context);
  await state.owner.invokeAsync("observe-reduce-motion", payload("1"), state.context);
  await state.owner.invokeAsync("observe-reduce-motion", payload("1"), state.context);
  assert.equal(installs, 1);
  assert.deepEqual(events, [
    ["0", false],
    ["1", false],
  ]);
  ids.delete("0");
  handler(true);
  assert.deepEqual(events.at(-1), ["1", true]);
  assert.equal(removals, 0);
  ids.clear();
  handler(false);
  assert.equal(removals, 1);
  const count = events.length;
  handler(true);
  assert.equal(events.length, count);
  state.owner.onDispose();
  assert.equal(removals, 1);
});

test("initial query failure rolls back only the new route and unsubscribes when empty", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 23 };
  const handlers = new Set();
  let fail = false;
  globalThis.accessibility = {
    onAnimationReduceStateChange: (handler) => handlers.add(handler),
    isAnimationReduceEnabledSync: () => {
      if (fail) throw new Error("query failed");
      return false;
    },
    offAnimationReduceStateChange: (handler) => handlers.delete(handler),
  };
  const state = plugin([]);
  await state.owner.invokeAsync("observe-reduce-motion", payload("0"), state.context);
  fail = true;
  await assert.rejects(
    state.owner.invokeAsync("observe-reduce-motion", payload("1"), state.context),
    /query failed/,
  );
  assert.deepEqual(Array.from(state.owner.motionIds), ["0"]);
  assert.equal(handlers.size, 1);
  await state.owner.invokeAsync("stop-observing-reduce-motion", payload("0"), state.context);
  await assert.rejects(
    state.owner.invokeAsync("observe-reduce-motion", payload("2"), state.context),
    /query failed/,
  );
  assert.equal(handlers.size, 0);
});

test("inactive or disposed owners reject new calls and ignore stale callbacks", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 23 };
  let handler;
  globalThis.accessibility = {
    onAnimationReduceStateChange: (value) => {
      handler = value;
    },
    isAnimationReduceEnabledSync: () => false,
    offAnimationReduceStateChange: () => {},
  };
  const events = [];
  const state = plugin(events);
  await state.owner.invokeAsync("observe-reduce-motion", payload("0"), state.context);
  state.context.isActive = () => false;
  handler(true);
  assert.deepEqual(events, [false]);
  await assert.rejects(
    state.owner.invokeAsync("observe-reduce-motion", payload("1"), state.context),
    /no longer active/,
  );
  state.owner.onDispose();
  state.context.isActive = () => true;
  handler(true);
  await assert.rejects(
    state.owner.invokeAsync("observe-reduce-motion", payload("1"), state.context),
    /no longer active/,
  );
  assert.deepEqual(events, [false]);
});

test("malformed motion values and wrong named types are rejected before registration", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 23 };
  globalThis.accessibility = {};
  const state = plugin([]);
  for (const value of [null, {}, { id: 1 }, { id: "" }, { id: "-1" }, { id: "1".repeat(21) }]) {
    await assert.rejects(
      state.owner.invokeAsync(
        "observe-reduce-motion",
        {
          typeName: "ohos.accessibility.MotionRequest",
          value,
        },
        state.context,
      ),
      /Invalid motion/,
    );
  }
  await assert.rejects(
    state.owner.invokeAsync(
      "observe-reduce-motion",
      {
        typeName: "std.string",
        value: { id: "0" },
      },
      state.context,
    ),
    /typeName/,
  );
});

test("screen-reader lifecycle recovery and disposal use the owner's exact callback", () => {
  globalThis.deviceInfo = { sdkApiVersion: 12 };
  const handlers = new Set();
  globalThis.accessibility = {
    on: (name, handler) => {
      assert.equal(name, "screenReaderStateChange");
      handlers.add(handler);
    },
    off: (name, handler) => {
      assert.equal(name, "screenReaderStateChange");
      assert.equal(handlers.has(handler), true);
      handlers.delete(handler);
    },
  };
  const a = plugin([], new Set(), true);
  const b = plugin([], new Set(), true);
  a.owner.onInstall(a.context);
  b.owner.onInstall(b.context);
  assert.equal(handlers.size, 2);
  a.owner.onDispose();
  assert.equal(handlers.size, 1);
  b.owner.onDispose();
  assert.equal(handlers.size, 0);
});

test("production Rust accessibility paths contain no worker, executor or replay queue", async () => {
  for (const name of ["lib.rs", "motion.rs", "motion_routes.rs"]) {
    const rust = await readFile(
      new URL(`../../../crates/plugin-accessibility/src/${name}`, import.meta.url),
      "utf8",
    );
    assert.doesNotMatch(
      rust,
      /std::thread|mpsc|block_on|futures_executor|enum Job|Job::|motion_stop/,
    );
  }
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
