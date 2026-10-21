import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import test from "node:test";
import vm from "node:vm";

async function production() {
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
    AppStorage: { setOrCreate() {}, get() {} },
  });
  const cache = new Map();
  async function load(name) {
    if (cache.has(name)) return cache.get(name);
    let source = await readFile(
      new URL(`../native_ability/src/main/ets/${name}.ets`, import.meta.url),
      "utf8",
    );
    if (name === "bridge/BridgeHost") source += "\nexport { BridgeHost };";
    const stripped = stripTypeScriptTypes(source);
    const imports = new Map();
    for (const match of stripped.matchAll(/import\s+([\s\S]*?)\s+from\s+["']([^"']+)["'];/g)) {
      const clause = match[1].trim();
      const names = [];
      const named = clause.match(/\{([\s\S]*)\}/);
      if (named)
        for (const field of named[1].split(",")) {
          const key = field.trim().split(/\s+as\s+/)[0];
          if (key) names.push(key);
        }
      if (!clause.startsWith("{") && !clause.startsWith("*")) names.push("default");
      imports.set(match[2], names);
    }
    const module = new vm.SourceTextModule(stripped, { context });
    cache.set(name, module);
    await module.link(async (specifier) => {
      if (
        specifier.startsWith("../runtime/") &&
        ["SerialTaskQueue", "CancellableTaskScope"].includes(specifier.split("/").at(-1))
      )
        return load(`runtime/${specifier.split("/").at(-1)}`);
      if (specifier === "../bridge/BridgeHost") return load("bridge/BridgeHost");
      const names = imports.get(specifier) ?? [];
      return new vm.SyntheticModule(
        names,
        function () {
          for (const key of names)
            this.setExport(key, key === "hilog" ? { error() {}, info() {}, warn() {} } : class {});
        },
        { context },
      );
    });
    return module;
  }
  const hostModule = await load("bridge/BridgeHost");
  await hostModule.evaluate();
  const abilityModule = await load("ability/NativeAbility");
  await abilityModule.evaluate();
  const { BridgeHost, BridgeHostRegistry } = hostModule.namespace;
  const { NativeAbility } = abilityModule.namespace;
  const host = new BridgeHost("session", "module", {}, []);
  host.abilityReady = true;
  BridgeHostRegistry.sessions.set("session", new Map([["module", host]]));
  const events = [];
  host.attachEventSink((plugin, event) => {
    events.push(`native:${plugin}:${event}`);
    return { accepted: true };
  });
  const ability = new NativeAbility();
  ability.bridgeSessionId = "session";
  ability.detachWindowListeners = () => events.push("detach-listeners");
  ability.forEachLifecycle = (callback) =>
    callback({ windowStageEventCallback: { onAbilityDestroy: () => events.push("rust-destroy") } });
  ability.enqueueLifecycleOperation = (label, operation) => {
    events.push(`queued:${label}`);
    return Promise.resolve();
  };
  return { host, BridgeHost, BridgeHostRegistry, ability, events, timers };
}
const invoke = (context) =>
  context.invokeNativeSync("release", "test.Request", "test.Response", {});
function plugin(host, id, onClosing, fields = {}) {
  host.plugins.set(id, {
    plugin: { id, requires: [], onClosing },
    installed: true,
    installAttempted: true,
    ...fields,
  });
}

test("actual NativeAbility.onDestroy detaches synchronously before native Rust destruction", async () => {
  const { host, ability, events } = await production();
  let saved;
  plugin(host, "first", (context) => {
    saved = context;
    invoke(context);
    host.beginClosing();
  });
  plugin(host, "failing", () => {
    throw new Error("injected failure");
  });
  plugin(host, "last", (context) => invoke(context));
  await ability.onDestroy();
  assert.deepEqual(events, [
    "detach-listeners",
    "native:first:release",
    "native:last:release",
    "rust-destroy",
    "queued:ability-destroy",
  ]);
  assert.throws(() => invoke(saved), /scope|cancel|closing|completed|active/i);
  host.beginClosing();
  assert.equal(events.filter((value) => value === "native:first:release").length, 1);
});

test("onClosing creation context is denied, partial-install owner cleans, Promise continuation is revoked", async () => {
  const { host, ability, events } = await production();
  const ordinary = host.pluginContext("partial");
  let continued = false;
  plugin(
    host,
    "partial",
    (context) => {
      assert.throws(() => invoke(ordinary), /closing/);
      invoke(context);
    },
    { installed: false },
  );
  plugin(host, "async", async (context) => {
    invoke(context);
    await Promise.resolve();
    assert.throws(() => invoke(context), /scope|cancel|closing|completed|active/i);
    continued = true;
  });
  await ability.onDestroy();
  await Promise.resolve();
  assert.equal(continued, true);
  assert.equal(events.filter((value) => value.startsWith("native:")).length, 2);
  assert.ok(events.indexOf("native:partial:release") < events.indexOf("rust-destroy"));
});

test("closing one Ability does not close a second host using the same plugin ID", async () => {
  const { host, BridgeHost, BridgeHostRegistry, ability, events } = await production();
  const other = new BridgeHost("second-session", "second-module", {}, []);
  other.abilityReady = true;
  BridgeHostRegistry.sessions.set("second-session", new Map([["second-module", other]]));
  let otherClosed = 0;
  plugin(host, "shared", (context) => invoke(context));
  plugin(other, "shared", () => {
    otherClosed++;
  });
  await ability.onDestroy();
  assert.equal(otherClosed, 0);
  assert.equal(other.closing, false);
  assert.equal(events.filter((value) => value === "native:shared:release").length, 1);
});
