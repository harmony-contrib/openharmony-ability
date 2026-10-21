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
const hilog = { debug() {}, info() {} }; let nextRenderOwnerId = 1;`;
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
  for (const id of [0, -1, 0x80000000, 1.5]) {
    await assert.rejects(appearance(0, id).aboutToAppear(), /invalid platform Window ID/);
  }
});
