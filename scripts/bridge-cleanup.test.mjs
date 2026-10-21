import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import test from "node:test";
import vm from "node:vm";

// Execute the production host and task scopes; only native effects are substituted.
async function runtime() {
  const timers = [];
  const context = vm.createContext({
    console,
    Date,
    Error,
    Map,
    Set,
    WeakSet,
    Promise,
    Number,
    Uint8Array,
    setTimeout: (callback) => {
      timers.push(callback);
      return timers.length;
    },
    clearTimeout: () => {},
  });
  const cache = new Map();
  async function load(name) {
    if (cache.has(name)) return cache.get(name);
    const path = new URL(`../native_ability/src/main/ets/${name}.ets`, import.meta.url);
    let source = await readFile(path, "utf8");
    if (name === "bridge/BridgeHost") source += "\nexport { BridgeHost };";
    const module = new vm.SourceTextModule(stripTypeScriptTypes(source), { context });
    cache.set(name, module);
    await module.link(async (specifier) => {
      if (specifier === "./ComponentWindow") return load("bridge/ComponentWindow");
      if (specifier.startsWith("../runtime/"))
        return load(`runtime/${specifier.split("/").at(-1)}`);
      const names = specifier.endsWith("/type")
        ? [
            "ApplicationLifecycle",
            "BridgeCallContext",
            "BridgeContextRequirement",
            "BridgeEmptyLifecyclePayload",
            "BridgeLifecycleEvent",
            "BridgeTypedValue",
            "AsyncBridgePlugin",
            "MainThreadSyncBridgePlugin",
            "BridgePlugin",
            "BridgePluginContext",
            "BridgePluginDeclaration",
            "BridgeDispatchHook",
            "BridgePluginFactory",
            "BridgePluginHookContext",
          ]
        : specifier.endsWith("/WindowManager")
          ? [
              "WindowManager",
              "WindowSizeEventWrap",
              "WindowRectEventWrap",
              "WindowAvoidAreaEventWrap",
            ]
          : specifier.endsWith(".node")
            ? ["FrameNode"]
            : specifier.endsWith(".UIContext")
              ? ["UIContext"]
              : specifier === "@kit.PerformanceAnalysisKit"
                ? ["hilog"]
                : ["default"];
      return new vm.SyntheticModule(
        names,
        function () {
          for (const key of names) {
            this.setExport(key, key === "hilog" ? { warn() {} } : class {});
          }
        },
        { context },
      );
    });
    return module;
  }
  const module = await load("bridge/BridgeHost");
  await module.evaluate();
  const host = new module.namespace.BridgeHost("session", "module", {}, []);
  const calls = [];
  host.abilityReady = true;
  host.plugins.set("test.plugin", { plugin: { id: "test.plugin", requires: [] }, installed: true });
  host.attachEventSink((...args) => {
    calls.push(args);
    return { accepted: true };
  });
  return { host, calls, timers };
}
const invoke = (context, event = "release") =>
  context.invokeNativeSync(event, "test.Request", "test.Response", {});

test("only the live destruction hook can call across closing, including after await", async () => {
  const { host, calls } = await runtime();
  const ordinary = host.pluginContext("test.plugin");
  host.beginClosing();
  let saved;
  await host.runPluginHook(
    "test.plugin",
    "dispose",
    async (context) => {
      saved = context;
      assert.throws(() => invoke(ordinary), /closing/);
      invoke(context);
      await Promise.resolve();
      invoke(context, "another-release");
    },
    true,
  );
  assert.equal(calls.length, 2);
  assert.equal(calls[0][0], "test.plugin");
  assert.throws(() => invoke(saved), /scope/);
});

test("cleanup still validates identifiers, registration and the native sink", async () => {
  const { host } = await runtime();
  await host.runPluginHook(
    "test.plugin",
    "dispose",
    async (context) => {
      assert.throws(() => invoke(context, "bad name"), /Invalid/);
      host.mainThreadEventSink = undefined;
      assert.throws(() => invoke(context), /sink/);
    },
    true,
  );
  await assert.rejects(
    host.runPluginHook("missing", "dispose", async (context) => invoke(context), true),
    /scope/,
  );
});

test("cancellation revokes a pending hook before its continuation resumes", async () => {
  const { host } = await runtime();
  let saved, resume;
  const pending = host.runPluginHook(
    "test.plugin",
    "destroy",
    async (context) => {
      saved = context;
      await new Promise((resolve) => {
        resume = resolve;
      });
      assert.throws(() => invoke(context), /scope/);
    },
    true,
  );
  await Promise.resolve();
  host.beginClosing();
  await assert.rejects(pending, /closing/);
  assert.throws(() => invoke(saved), /scope/);
  resume();
});

test("timeout revokes cleanup and does not grant ordinary hooks closing access", async () => {
  const { host, timers } = await runtime();
  let saved;
  const pending = host.runPluginHook(
    "test.plugin",
    "dispose",
    async (context) => {
      saved = context;
      await new Promise(() => {});
    },
    true,
  );
  await Promise.resolve();
  timers.at(-1)();
  await assert.rejects(pending, /timed out/);
  assert.throws(() => invoke(saved), /scope/);
  host.closing = true;
  await assert.rejects(
    host.runPluginHook("test.plugin", "install", async (context) => invoke(context)),
    /closing/,
  );
});

test("closing retires each owner once, survives failure and revokes saved contexts", async () => {
  const { host, calls } = await runtime();
  let saved;
  const first = host.plugins.get("test.plugin");
  first.plugin.onClosing = (context) => {
    saved = context;
    invoke(context);
    host.beginClosing();
    throw new Error("one owner's failure");
  };
  host.plugins.set("test.partial", {
    installed: false,
    installAttempted: true,
    plugin: { id: "test.partial", requires: [], onClosing: (context) => invoke(context) },
  });
  host.beginClosing();
  host.beginClosing();
  assert.deepEqual(
    calls.map((call) => call[0]),
    ["test.plugin", "test.partial"],
  );
  assert.throws(() => invoke(saved), /scope/);
});

test("Promise closing hooks cannot dispatch after yielding or prevent other owners", async () => {
  const { host, calls } = await runtime();
  let resumed;
  host.plugins.get("test.plugin").plugin.onClosing = async (context) => {
    await Promise.resolve();
    assert.throws(() => invoke(context), /scope/);
    resumed = true;
  };
  host.plugins.set("test.second", {
    installed: true,
    plugin: { id: "test.second", requires: [], onClosing: (context) => invoke(context) },
  });
  host.beginClosing();
  await Promise.resolve();
  assert.equal(resumed, true);
  assert.deepEqual(
    calls.map((call) => call[0]),
    ["test.second"],
  );
});

test("cleanup permits cannot be reused by a replacement registration", async () => {
  const { host } = await runtime();
  await host.runPluginHook(
    "test.plugin",
    "dispose",
    async (context) => {
      host.plugins.set("test.plugin", { plugin: { id: "test.plugin" }, installed: true });
      assert.throws(() => invoke(context), /scope/);
    },
    true,
  );
});
