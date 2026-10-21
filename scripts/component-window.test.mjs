import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import test from "node:test";
const root = "../native_ability/src/main/ets/";
const helper = await readFile(
  new URL(root + "bridge/ComponentWindow.ets", import.meta.url),
  "utf8",
);
const component = await readFile(
  new URL(root + "components/DefaultXComponent.ets", import.meta.url),
  "utf8",
);
// Execute the actual appearance method and window resolver; stub only platform
// objects/render effects. ArkUI build syntax is outside this lifecycle method.
const method = component.slice(
  component.indexOf("  async aboutToAppear"),
  component.indexOf("  aboutToDisappear"),
);
const importsRemoved = helper.replace(/^import .*;\n/gm, "");
const prefix = `const window = { findWindow: name => globalThis.testWindows.get(name) };
const NativeModuleLoader = { load: async () => globalThis.nativeModule };
const WindowManager = { getInstance: () => ({ applyTransparentBackground() {} }) };
const BridgeHostRegistry = { attachComponent: async () => {} };
const hilog = { debug() {}, info() {}, warn() {} }; let nextRenderOwnerId = 1;`;
const { Component } = await import(
  `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(prefix + importsRemoved + "\nexport class Component {" + method + "}")).toString("base64")}`
);
function appearance(routingId, nativeId) {
  const owner = new Component();
  Object.assign(owner, {
    appearanceGeneration: 0,
    releasePromise: Promise.resolve(),
    moduleName: "module",
    windowId: routingId,
    bridgeSessionId: "session",
    rootSlot: {},
    nodeController: { makeNode: () => ({}) },
    attachSurfaceBlur: () => {},
    getUIContext: () => ({ getWindowName: () => "component" }),
  });
  globalThis.testWindows = new Map([
    ["component", { getWindowProperties: () => ({ id: nativeId }) }],
  ]);
  return owner;
}
test("main routing ID zero forwards the positive platform Window ID", async () => {
  const calls = [];
  globalThis.nativeModule = { render: (...args) => calls.push(args), disposeRender: () => {} };
  await appearance(0, 201).aboutToAppear();
  assert.equal(calls.length, 1);
  assert.equal(calls[0][2], 201);
});
test("subwindow routing ID stays distinct from the actual platform Window ID", async () => {
  const calls = [];
  globalThis.nativeModule = {
    renderWindow: (...args) => calls.push(args),
    disposeRender: () => {},
  };
  await appearance(77, 303).aboutToAppear();
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].slice(2), [77, 303]);
});
test("invalid platform Window identity fails before native render", async () => {
  globalThis.nativeModule = {
    render: () => assert.fail("render called with invalid ID"),
    disposeRender: () => {},
  };
  for (const id of [-1, 0x80000000, 1.5, NaN]) {
    await assert.rejects(appearance(0, id).aboutToAppear(), /invalid platform Window ID/);
  }
});
test("zero explicitly selects the main platform Window", async () => {
  const calls = [];
  globalThis.nativeModule = { render: (...args) => calls.push(args), disposeRender() {} };
  await appearance(0, 0).aboutToAppear();
  assert.equal(calls[0][2], 0);
});
test("unavailable main Window lookup does not prevent rendering", async () => {
  for (const context of [
    { getWindowName: () => "" },
    { getWindowName: () => "not-ready" },
    {
      getWindowName: () => {
        throw new Error("UIContext not ready");
      },
    },
  ]) {
    const calls = [];
    globalThis.nativeModule = { render: (...args) => calls.push(args), disposeRender() {} };
    const owner = appearance(0, 201);
    owner.getUIContext = () => context;
    await owner.aboutToAppear();
    assert.equal(calls[0][2], 0);
  }
});
test("a subwindow never silently targets the main Window", async () => {
  globalThis.nativeModule = {
    renderWindow: () => assert.fail("render called without a subwindow identity"),
    disposeRender() {},
  };
  const owner = appearance(77, 0);
  await assert.rejects(owner.aboutToAppear(), /invalid platform Window ID/);
  owner.getUIContext = () => ({ getWindowName: () => "" });
  await assert.rejects(owner.aboutToAppear(), /Cannot resolve sub-window/);
});
