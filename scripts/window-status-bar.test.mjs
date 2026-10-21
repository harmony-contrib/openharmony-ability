import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import test from "node:test";
import vm from "node:vm";

const TYPE = "ohos.window.StatusBarRequest";
const request = (values = {}) => ({
  windowId: 0,
  enabled: true,
  lightContent: true,
  animated: false,
  ...values,
});
const deferred = () => {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
};

async function runtime() {
  const calls = [];
  const windows = new Map();
  const state = { active: true };
  const makeWindow = (id) => ({
    async setWindowSystemBarProperties(properties) {
      calls.push([id, "properties", { ...properties }]);
    },
    async setSpecificSystemBarEnabled(...values) {
      calls.push([id, "visibility", ...values]);
    },
  });
  const component = makeWindow(10);
  const context = { isActive: () => state.active, getWindow: () => component };
  const exports = {
    default: {},
    image: {},
    pointer: {},
    setWindowIcon() {},
    parseCustomCursor() {},
    BusinessError: class {},
    deviceInfo: { sdkApiVersion: 26 },
    hilog: {},
    notificationManager: {},
    inputMethod: {},
    DOMAIN: 0,
    BridgeAcknowledgement: class {
      constructor(accepted) {
        this.accepted = accepted;
      }
    },
    BridgeCallContext: class {},
    BridgePluginHookContext: class {},
    BridgeTypedValue: class {},
    BridgeContextRequirement: class {},
    AsyncPluginBase: class {},
    WindowManager: { getInstance: () => ({ getWindow: (id) => windows.get(id) }) },
    PromptDialogs: class {},
    WindowPromptRequest: class {},
  };
  const sandbox = vm.createContext({ console, Map, Set, Number, String, Error, Promise, Array });
  const source = await readFile(
    new URL("../plugins/window/src/main/ets/WindowPlugin.ets", import.meta.url),
    "utf8",
  );
  const module = new vm.SourceTextModule(stripTypeScriptTypes(source), { context: sandbox });
  await module.link(
    async () =>
      new vm.SyntheticModule(
        Object.keys(exports),
        function () {
          for (const [name, value] of Object.entries(exports)) this.setExport(name, value);
        },
        { context: sandbox },
      ),
  );
  await module.evaluate();
  const plugin = new module.namespace.WindowPlugin();
  const invoke = (...args) =>
    plugin.invokeAsync(
      "set-status-bar",
      { typeName: args[1] ?? TYPE, value: args.length ? args[0] : request() },
      context,
    );
  return { plugin, context, state, calls, component, windows, makeWindow, invoke };
}

test("status updates route through existing component, owned and registry windows", async () => {
  const r = await runtime();
  r.plugin.windows.set(20, r.makeWindow(20));
  r.windows.set(30, r.makeWindow(30));
  for (const id of [0, 20, 30]) {
    const result = await r.invoke(request({ windowId: id, background: 0x00123456 }));
    assert.equal(result.typeName, "ohos.window.Acknowledgement");
    assert.equal(result.value.accepted, true);
  }
  assert.deepEqual(
    r.calls.map((call) => call[0]),
    [10, 10, 20, 20, 30, 30],
  );
  assert.deepEqual(r.calls[0][2], {
    statusBarContentColor: "#ffffffff",
    statusBarColor: "#00123456",
  });
  for (const call of r.calls.filter((call) => call[1] === "visibility")) {
    assert.deepEqual(call.slice(2), ["status", true, false]);
  }
  await assert.rejects(r.invoke(request({ windowId: 99 })), /Unknown OS sub-window/);
});

test("optional background leaves existing color fields untouched and accepts ARGB bounds", async () => {
  const r = await runtime();
  for (const background of [undefined, null]) {
    await r.invoke(request({ background, lightContent: false, enabled: false, animated: true }));
  }
  assert.deepEqual(r.calls[0][2], { statusBarContentColor: "#ff000000" });
  assert.deepEqual(r.calls[2][2], { statusBarContentColor: "#ff000000" });
  assert.deepEqual(r.calls[1].slice(2), ["status", false, true]);
  await r.invoke(request({ background: 0xffffffff }));
  assert.equal(r.calls[4][2].statusBarColor, "#ffffffff");
  for (const call of r.calls.filter((call) => call[1] === "properties")) {
    assert.ok(Object.keys(call[2]).every((key) => key.startsWith("statusBar")));
  }
});

test("invalid named values are rejected before any platform mutation", async () => {
  const r = await runtime();
  await assert.rejects(r.invoke(request(), "other.Request"), /requires/);
  for (const value of [null, undefined, "text", 1]) await assert.rejects(r.invoke(value));
  for (const windowId of [-1, NaN, Infinity, 0.5, Number.MAX_SAFE_INTEGER + 1]) {
    await assert.rejects(r.invoke(request({ windowId })), /Invalid status-bar/);
  }
  for (const background of [-1, 0x100000000, NaN, Infinity, 0.5, "#ffffff"]) {
    await assert.rejects(r.invoke(request({ background })), /Invalid status-bar/);
  }
  for (const key of ["enabled", "lightContent", "animated"]) {
    await assert.rejects(r.invoke(request({ [key]: 1 })), /Invalid status-bar/);
  }
  assert.equal(r.calls.length, 0);
});

test("resolution and both native promises complete before acknowledgement", async () => {
  const r = await runtime();
  const resolution = deferred(),
    properties = deferred(),
    visibility = deferred();
  let resolvedId,
    acknowledged = false;
  r.plugin.requireWindow = async (id) => {
    resolvedId = id;
    await resolution.promise;
    return r.component;
  };
  r.component.setWindowSystemBarProperties = async () => {
    r.calls.push("properties");
    await properties.promise;
  };
  r.component.setSpecificSystemBarEnabled = async () => {
    r.calls.push("visibility");
    await visibility.promise;
  };
  const pending = r.invoke(request({ windowId: 42 })).then(() => {
    acknowledged = true;
  });
  assert.equal(resolvedId, 42);
  assert.equal(r.calls.length, 0);
  resolution.resolve();
  await new Promise(setImmediate);
  assert.deepEqual(r.calls, ["properties"]);
  properties.resolve();
  await new Promise(setImmediate);
  assert.deepEqual(r.calls, ["properties", "visibility"]);
  assert.equal(acknowledged, false);
  visibility.resolve();
  await pending;
  assert.equal(acknowledged, true);
});

test("closure after resolution or a native await stops subsequent work and acknowledgement", async () => {
  for (const phase of ["resolve", "properties", "visibility"]) {
    const r = await runtime();
    if (phase === "resolve")
      r.plugin.requireWindow = async () => {
        r.state.active = false;
        return r.component;
      };
    if (phase === "properties")
      r.component.setWindowSystemBarProperties = async () => {
        r.state.active = false;
      };
    if (phase === "visibility")
      r.component.setSpecificSystemBarEnabled = async () => {
        r.state.active = false;
      };
    await assert.rejects(r.invoke(), /no longer active/);
    if (phase !== "visibility") assert.ok(!r.calls.some((call) => call[1] === "visibility"));
  }
  const r = await runtime();
  r.component.setWindowSystemBarProperties = async () => {
    throw new Error("platform rejection");
  };
  await assert.rejects(r.invoke(), /platform rejection/);
  assert.equal(r.calls.length, 0);
});
