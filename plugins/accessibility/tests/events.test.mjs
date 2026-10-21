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
const request = (value, type = "SendEventRequest") => ({
  typeName: `ohos.accessibility.${type}`,
  value,
});
const context = () => ({
  isActive: () => true,
  abilityContext: { abilityInfo: { bundleName: "test.owner" } },
});

test("send-event preserves announcement text and focus IDs at the API-12 boundary", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 12 };
  const events = [];
  globalThis.accessibility = { sendAccessibilityEvent: async (value) => events.push(value) };
  const owner = new AccessibilityPlugin();
  for (const value of [
    { announcement: "" },
    { announcement: "  " },
    { elementId: 0 },
    { elementId: 0x7fffffff },
  ]) {
    const result = await owner.invokeAsync("send-event", request(value), context());
    assert.deepEqual(result, {
      typeName: "ohos.accessibility.EventAcknowledgement",
      value: { accepted: true },
    });
  }
  assert.deepEqual(events, [
    {
      type: "announceForAccessibility",
      bundleName: "test.owner",
      triggerAction: "common",
      textAnnouncedForAccessibility: "",
    },
    {
      type: "announceForAccessibility",
      bundleName: "test.owner",
      triggerAction: "common",
      textAnnouncedForAccessibility: "  ",
    },
    {
      type: "requestFocusForAccessibility",
      bundleName: "test.owner",
      triggerAction: "common",
      elementId: 0,
    },
    {
      type: "requestFocusForAccessibility",
      bundleName: "test.owner",
      triggerAction: "common",
      elementId: 0x7fffffff,
    },
  ]);
});

test("live announcements pass the caller's interruption choice to the platform on API 18", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 18 };
  const events = [];
  globalThis.accessibility = { sendAccessibilityEvent: async (value) => events.push(value) };
  const owner = new AccessibilityPlugin();
  for (const assertive of [false, true]) {
    const result = await owner.invokeAsync(
      "announce-live",
      request(
        {
          text: "new text",
          assertive,
        },
        "LiveAnnouncement",
      ),
      context(),
    );
    assert.equal(result.typeName, "ohos.accessibility.EventAcknowledgement");
    assert.equal(result.value.accepted, true);
  }
  assert.deepEqual(
    events.map((value) => value.type),
    ["announceForAccessibilityNotInterrupt", "announceForAccessibility"],
  );
});

test("invalid values, unsupported APIs and wrong ABI names never send a system event", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 23 };
  globalThis.accessibility = { sendAccessibilityEvent: () => assert.fail("invalid event sent") };
  const owner = new AccessibilityPlugin();
  for (const value of [
    null,
    {},
    { announcement: 1 },
    { elementId: -1 },
    { elementId: 0x80000000 },
    { elementId: 0.5 },
    { elementId: NaN },
    { announcement: "a", elementId: 1 },
  ]) {
    await assert.rejects(owner.invokeAsync("send-event", request(value), context()));
  }
  for (const value of [null, {}, { text: 1, assertive: false }, { text: "a", assertive: 0 }]) {
    await assert.rejects(
      owner.invokeAsync("announce-live", request(value, "LiveAnnouncement"), context()),
    );
  }
  await assert.rejects(
    owner.invokeAsync("send-event", request({ announcement: "x" }, "Wrong"), context()),
    /typeName/,
  );
  await assert.rejects(
    owner.invokeAsync(
      "announce-live",
      request({ text: "x", assertive: false }, "Wrong"),
      context(),
    ),
    /typeName/,
  );
  globalThis.deviceInfo.sdkApiVersion = 17;
  await assert.rejects(
    owner.invokeAsync(
      "announce-live",
      request({ text: "x", assertive: true }, "LiveAnnouncement"),
      context(),
    ),
    /API 18/,
  );
  globalThis.deviceInfo.sdkApiVersion = 11;
  await assert.rejects(
    owner.invokeAsync("send-event", request({ announcement: "x" }), context()),
    /API 12/,
  );
});

test("system failures and a session closed during await cannot report success", async () => {
  globalThis.deviceInfo = { sdkApiVersion: 23 };
  const owner = new AccessibilityPlugin();
  globalThis.accessibility = {
    sendAccessibilityEvent: async () => {
      throw new Error("permission denied code=201");
    },
  };
  await assert.rejects(
    owner.invokeAsync("send-event", request({ elementId: 1 }), context()),
    /code=201/,
  );
  const callContext = context();
  globalThis.accessibility.sendAccessibilityEvent = async () => {
    callContext.isActive = () => false;
  };
  await assert.rejects(
    owner.invokeAsync("send-event", request({ announcement: "x" }), callContext),
    /session closed/,
  );
  callContext.isActive = () => true;
  await assert.rejects(
    owner.invokeAsync(
      "announce-live",
      request({ text: "x", assertive: false }, "LiveAnnouncement"),
      callContext,
    ),
    /session was closed/,
  );
});
