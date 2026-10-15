// Run via pnpm run test:runtime with Node 22+ and OHOS_SDK_HOME pointing at the SDK.
// The SDK parser loads real ArkTS classes; only platform APIs and the UI builder
// are mocked. These tests verify ordering, failure rollback and session ownership.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const root = path.resolve(process.env.RUNTIME_REPO_ROOT || path.resolve(__dirname, ".."));
const sdk = process.env.OHOS_SDK_HOME;
if (!sdk) throw new Error("Set OHOS_SDK_HOME to the SDK directory containing ets/.");
const ts = require(path.join(sdk, "ets/build-tools/ets-loader/node_modules/typescript"));
const quietConsole = { warn() {}, info() {}, debug() {}, error() {} };
const windowApi = {
  WindowStatusType: { MINIMIZE: 1, MAXIMIZE: 2, FLOATING: 3 },
  WindowEventType: { WINDOW_ACTIVE: 1, WINDOW_INACTIVE: 2, WINDOW_SHOWN: 3 },
  AvoidAreaType: { TYPE_SYSTEM: 0 },
  MaximizePresentation: { FOLLOW_APP_IMMERSIVE_SETTING: 0 },
};
const base = {
  AsyncPluginBase: class {},
  BridgeAcknowledgement: class {
    constructor(accepted) {
      this.accepted = accepted;
    }
  },
  DOMAIN: 0,
  expectBridgeRequestType(payload, _plugin, _action, type) {
    assert.equal(payload.typeName, type);
    return payload.value;
  },
};
const deviceInfo = { sdkApiVersion: 20 };

function loader(overrides = {}, globals = {}) {
  const imports = {
    "@kit.ArkUI": { window: windowApi },
    "@kit.AbilityKit": {},
    "@kit.NotificationKit": {},
    "@kit.IMEKit": {},
    "@kit.ImageKit": {},
    "@kit.BasicServicesKit": { deviceInfo },
    "@kit.PerformanceAnalysisKit": { hilog: quietConsole },
    "@ohos.window": windowApi,
    "@ohos.display": {
      getDefaultDisplaySync: () => ({ width: 1200, on() {}, off() {} }),
      on() {},
      off() {},
    },
    "@ohos-rs/ability": { ...base },
    "@ohos.multimodalInput.pointer": {},
    "../components/FloatPage": { RouteName: "FloatPage" },
    "../components/MenuBarSlot": { getMenuBarPort: () => undefined },
    "../helper/constants": { DOMAIN: 0 },
    "../helper/window_flags": { clearClipboardEnabled() {}, clearZoomHotkeysEnabled() {} },
    ...overrides,
  };
  const cache = new Map();
  const load = (relative) => {
    const filename = path.resolve(root, relative);
    if (cache.has(filename)) return cache.get(filename).exports;
    const module = { exports: {} };
    cache.set(filename, module);
    const source = fs.readFileSync(filename, "utf8");
    const ast = ts.createSourceFile(
      filename,
      source,
      ts.ScriptTarget.Latest,
      true,
      ts.ScriptKind.ETS,
    );
    // ComponentContent layout is covered by platform compilation. Keep its model,
    // session and cancellation code unchanged while omitting declarative UI syntax.
    const statements = ast.statements.filter(
      (s) => !(ts.isFunctionDeclaration(s) && s.name?.text === "promptBuilder"),
    );
    const printed = ts.createPrinter().printFile(ts.factory.updateSourceFile(ast, statements));
    const { outputText } = ts.transpileModule(printed, {
      fileName: filename.replace(/\.ets$/, ".ts"),
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
    });
    const context = vm.createContext({
      exports: module.exports,
      module,
      console: quietConsole,
      setTimeout,
      clearTimeout,
      Uint8Array,
      ArrayBuffer,
      DialogAlignment: { TopStart: 0, Center: 1 },
      wrapBuilder: (builder) => builder,
      promptBuilder() {},
      LocalStorage: class {
        values = new Map();
        setOrCreate(key, value) {
          this.values.set(key, value);
        }
        get(key) {
          return this.values.get(key);
        }
      },
      require(specifier) {
        if (specifier in imports) return { default: imports[specifier], ...imports[specifier] };
        if (specifier.startsWith("."))
          return load(
            path.relative(root, path.resolve(path.dirname(filename), specifier + ".ets")),
          );
        throw new Error(`Unmocked platform import: ${specifier}`);
      },
      ...globals,
    });
    vm.runInContext(outputText, context, { filename });
    return module.exports;
  };
  return { load, imports };
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
const flush = () => new Promise((resolve) => setImmediate(resolve));
const managerPath = "native_ability/src/main/ets/window/WindowManager.ets";
function managerFor(l = loader()) {
  const { WindowManager } = l.load(managerPath);
  WindowManager.init({});
  const manager = WindowManager.getInstance();
  l.imports["@ohos-rs/ability"].WindowManager = WindowManager;
  return { manager, l };
}

test("URI and record clipboard APIs both round-trip in caller order", async () => {
  let stored;
  class PasteData {
    constructor(record) {
      this.records = [record];
    }
    addRecord(record, value) {
      this.records.unshift(value === undefined ? record : { mimeType: record, uri: value });
    }
    replaceRecord(index, record) {
      this.records[index] = record;
    }
    getRecordCount() {
      return this.records.length;
    }
    getRecordAt(index) {
      return this.records[index];
    }
    getMimeTypes() {
      return ["uri"];
    }
  }
  const pasteboard = {
    MIMETYPE_TEXT_URI: "uri",
    MIMETYPE_TEXT_PLAIN: "text",
    MIMETYPE_PIXELMAP: "image",
    createData: (type, value) => new PasteData({ mimeType: type, uri: value }),
    createRecord: (type, value) => ({ mimeType: type, uri: value }),
    getSystemPasteboard: () => ({
      setData: async (data) => {
        stored = data;
      },
      getData: async () => stored,
    }),
  };
  const { ClipboardPlugin } = loader({
    "@ohos.pasteboard": pasteboard,
    "@kit.ImageKit": {},
    "@kit.ArkTS": {},
  }).load("plugins/clipboard/src/main/ets/ClipboardPlugin.ets");
  const plugin = new ClipboardPlugin({ metadataMimeType: "application/x-test-metadata-v1" });
  const uris = ["file://A", "file://B", "file://C"];
  const context = { isActive: () => true };
  await plugin.invokeAsync(
    "write-uris",
    { typeName: "ohos.clipboard.WriteUrisRequest", value: { uris } },
    context,
  );
  const content = await plugin.invokeAsync(
    "read-content",
    { typeName: "ohos.clipboard.ReadTextRequest", value: {} },
    context,
  );
  assert.deepEqual(Array.from(content.value.uris), uris);
  await plugin.invokeAsync(
    "write-records",
    {
      typeName: "ohos.clipboard.WriteRecordsRequest",
      value: { records: uris.map((uri) => ({ uri })) },
    },
    context,
  );
  const records = await plugin.invokeAsync(
    "read-records",
    { typeName: "ohos.clipboard.ReadTextRequest", value: {} },
    context,
  );
  assert.deepEqual(
    Array.from(records.value.records, (record) => record.uri),
    uris,
  );
});

test("failed sub-window initialization destroys and unregisters every resource", async () => {
  for (const phase of ["load", "resize", "move", "show", "replay", "cleanup"]) {
    const { manager } = managerFor();
    const original = new Error(phase);
    const handlers = new Map();
    let destroyed = 0,
      moves = 0;
    const win = {
      on(name, fn) {
        handlers.set(name, fn);
      },
      off(name) {
        handlers.delete(name);
      },
      async loadContentByName() {
        if (phase === "load" || phase === "cleanup") throw original;
      },
      getUIContext: () => ({}),
      async resize() {
        if (phase === "resize") throw original;
      },
      async moveWindowTo() {
        moves++;
        if (phase === "move" || (phase === "replay" && moves === 2)) throw original;
      },
      async showWindow() {
        if (phase === "show") throw original;
      },
      async destroyWindow() {
        destroyed++;
        if (phase === "cleanup") throw new Error("destroy failed");
      },
    };
    manager.registerUIAbilityStage(
      0,
      { getMainWindowSync: () => ({ on() {} }), createSubWindowWithOptions: async () => win },
      {},
    );
    await assert.rejects(
      manager.createSubWindow({ windowId: 7, name: "test" }),
      (error) => error === original,
    );
    assert.equal(destroyed, 1, phase);
    assert.equal(manager.getWindow(7), undefined, phase);
    assert.equal(manager.getUIContext(7), undefined, phase);
    assert.equal(handlers.size, 0, phase);
  }
});

test("API 14 display requests are rejected before creating a window", async () => {
  const l = loader({ "@kit.BasicServicesKit": { deviceInfo: { sdkApiVersion: 14 } } });
  const { manager } = managerFor(l);
  let created = 0;
  manager.registerUIAbilityStage(
    0,
    {
      getMainWindowSync: () => ({ on() {} }),
      createSubWindow: async () => {
        created++;
      },
    },
    {},
  );
  await assert.rejects(
    manager.createSubWindow({ windowId: 1, name: "test", displayId: 0 }),
    /API 15/,
  );
  assert.equal(created, 0);
});

test("restore inspects queued state, waits for the OS and propagates failure without poisoning the queue", async () => {
  const { manager } = managerFor();
  const preceding = deferred(),
    restoring = deferred();
  let state = windowApi.WindowStatusType.MAXIMIZE,
    restoreCalls = 0;
  const win = {
    getWindowStatus: () => state,
    restore() {
      restoreCalls++;
      return restoring.promise;
    },
  };
  const first = manager.serializeOp(0, async () => {
    await preceding.promise;
    state = windowApi.WindowStatusType.MINIMIZE;
  });
  const result = manager.restoreWindow(0, { window: win, onlyIfMinimized: true });
  const failure = new Error("OS restore failure");
  const rejected = assert.rejects(result, (error) => error === failure);
  await flush();
  assert.equal(restoreCalls, 0);
  preceding.resolve();
  await first;
  await flush();
  assert.equal(restoreCalls, 1);
  restoring.reject(failure);
  await rejected;
  let nextRan = false;
  await manager.serializeOp(0, async () => {
    nextRan = true;
  });
  assert.equal(nextRan, true);
});

test("focus awaits restoration; showing a maximized main window does not restore it", async () => {
  const { manager, l } = managerFor();
  const restoring = deferred();
  let state = windowApi.WindowStatusType.MINIMIZE,
    restoreCalls = 0;
  const win = {
    getWindowStatus: () => state,
    restore() {
      restoreCalls++;
      return restoring.promise;
    },
    on() {},
  };
  manager.registerUIAbilityStage(0, { getMainWindowSync: () => win }, {});
  const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
  const plugin = new WindowPlugin();
  const payload = { typeName: "ohos.window.WindowIdRequest", value: { windowId: 0 } };
  const context = { isActive: () => true, getWindow: () => win };
  let completed = false;
  const result = plugin.invokeAsync("focus", payload, context).then(() => {
    completed = true;
  });
  await flush();
  assert.equal(restoreCalls, 1);
  assert.equal(completed, false);
  restoring.resolve();
  await result;
  state = windowApi.WindowStatusType.MAXIMIZE;
  await plugin.invokeAsync("show", payload, context);
  assert.equal(restoreCalls, 1);
});

test("restore on API 13 rejects without calling the unsupported platform method", async () => {
  const { manager } = managerFor(
    loader({ "@kit.BasicServicesKit": { deviceInfo: { sdkApiVersion: 13 } } }),
  );
  let calls = 0;
  await assert.rejects(
    manager.restoreWindow(0, {
      window: {
        restore() {
          calls++;
        },
      },
    }),
    /API 14/,
  );
  assert.equal(calls, 0);
});

test("a canceled queued focus does not restore the window after its session ends", async () => {
  const { manager, l } = managerFor();
  const preceding = deferred();
  let active = true,
    calls = 0;
  const win = {
    on() {},
    getWindowStatus: () => windowApi.WindowStatusType.MINIMIZE,
    async restore() {
      calls++;
    },
  };
  manager.registerUIAbilityStage(0, { getMainWindowSync: () => win }, {});
  const first = manager.serializeOp(0, () => preceding.promise);
  const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
  const result = new WindowPlugin().invokeAsync(
    "focus",
    { typeName: "ohos.window.WindowIdRequest", value: { windowId: 0 } },
    { isActive: () => active, getWindow: () => win },
  );
  const rejected = assert.rejects(result, /no longer active/);
  active = false;
  preceding.resolve();
  await first;
  await rejected;
  assert.equal(calls, 0);
});

test("thermal ownership survives another instance disposing and dispatches once per host", async () => {
  let callback,
    registrations = 0,
    removals = 0;
  const thermal = {
    registerThermalLevelCallback(fn) {
      registrations++;
      callback = fn;
    },
    unregisterThermalLevelCallback() {
      removals++;
      callback = undefined;
    },
  };
  const common = {
    Support: {},
    createSubscriber: async () => ({}),
    subscribe() {},
    unsubscribe(_subscriber, done) {
      done();
    },
  };
  const { SystemStatePlugin } = loader({
    "@ohos.thermal": thermal,
    "@ohos.commonEventManager": common,
  }).load("plugins/system-state/src/main/ets/SystemStatePlugin.ets");
  const a = new SystemStatePlugin(),
    b = new SystemStatePlugin();
  const receivedA = [],
    receivedB = [];
  const context = (received) => ({
    isActive: () => true,
    invokeNativeSync(_event, _req, _res, value) {
      received.push(value.thermalLevel);
    },
  });
  a.onInstall(context(receivedA));
  b.onInstall(context(receivedB));
  await flush();
  assert.equal(registrations, 1);
  callback(2);
  assert.deepEqual(receivedA, [2]);
  assert.deepEqual(receivedB, [2]);
  await a.onDispose();
  assert.equal(removals, 0);
  callback(3);
  assert.deepEqual(receivedA, [2]);
  assert.deepEqual(receivedB, [2, 3]);
  await b.onDispose();
  await b.onDispose();
  assert.equal(removals, 1);
});

test("a late common-event subscriber is released and unsubscribe exceptions do not fail disposal", async () => {
  const pending = deferred();
  let unsubscribed = 0;
  const common = {
    Support: {},
    createSubscriber: () => pending.promise,
    unsubscribe() {
      unsubscribed++;
      throw new Error("already gone");
    },
  };
  const thermal = { registerThermalLevelCallback() {}, unregisterThermalLevelCallback() {} };
  const { SystemStatePlugin } = loader({
    "@ohos.thermal": thermal,
    "@ohos.commonEventManager": common,
  }).load("plugins/system-state/src/main/ets/SystemStatePlugin.ets");
  const plugin = new SystemStatePlugin();
  plugin.onInstall({ isActive: () => true });
  await plugin.onDispose();
  pending.resolve({});
  await flush();
  assert.equal(unsubscribed, 1);
});

test("a failed thermal registration cannot unregister another instance's subscription", async () => {
  let callback,
    attempts = 0,
    removals = 0;
  const thermal = {
    registerThermalLevelCallback(fn) {
      if (++attempts === 1) throw new Error("unavailable");
      callback = fn;
    },
    unregisterThermalLevelCallback() {
      removals++;
    },
  };
  const common = {
    Support: {},
    createSubscriber: async () => ({}),
    subscribe() {},
    unsubscribe(_subscriber, done) {
      done();
    },
  };
  const { SystemStatePlugin } = loader({
    "@ohos.thermal": thermal,
    "@ohos.commonEventManager": common,
  }).load("plugins/system-state/src/main/ets/SystemStatePlugin.ets");
  const a = new SystemStatePlugin(),
    b = new SystemStatePlugin();
  let received = 0;
  a.onInstall({ isActive: () => true });
  b.onInstall({
    isActive: () => true,
    invokeNativeSync() {
      received++;
    },
  });
  await flush();
  await a.onDispose();
  assert.equal(removals, 0);
  callback(2);
  assert.equal(received, 1);
  await b.onDispose();
  assert.equal(removals, 1);
});

test("anchored prompts use target-window density, measured height and new window bounds", async () => {
  let content,
    options,
    updated,
    sizeListener,
    closes = 0,
    disposed = 0;
  const ComponentContent = class {
    constructor(_ui, _builder, model) {
      this.model = model;
      content = this;
    }
    update(model) {
      this.model = model;
    }
    dispose() {
      disposed++;
    }
  };
  const prompt = {
    async openCustomDialog(_content, value) {
      options = value;
    },
    async updateCustomDialog(_content, value) {
      updated = value;
    },
    async closeCustomDialog() {
      closes++;
    },
  };
  const ui = { px2vp: (px) => px / 3, getPromptAction: () => prompt };
  const rect = { width: 1200, height: 1800 };
  const win = {
    getUIContext: () => ui,
    getWindowProperties: () => ({ windowRect: rect }),
    getWindowAvoidArea: () => ({
      leftRect: { width: 0 },
      rightRect: { width: 0 },
      topRect: { height: 60 },
      bottomRect: { height: 120 },
    }),
    on(_name, listener) {
      sizeListener = listener;
    },
    off() {
      sizeListener = undefined;
    },
  };
  const { PromptDialogs } = loader({ "@kit.ArkUI": { window: windowApi, ComponentContent } }).load(
    "plugins/window/src/main/ets/PromptDialogs.ets",
  );
  const dialogs = new PromptDialogs();
  const result = dialogs.show(
    win,
    { message: "Test", level: 0, buttons: ["OK"], anchor: { x: 380, y: 530 } },
    { isActive: () => true, onCancel: () => () => {} },
  );
  await flush();
  assert.equal(options.offset.dx, 160);
  assert.equal(options.offset.dy, 54);
  content.model.measure(240, 150);
  await flush();
  assert.equal(updated.offset.dx, 160);
  assert.equal(updated.offset.dy, 390);
  rect.width = 300;
  rect.height = 600;
  sizeListener({ width: rect.width, height: rect.height });
  await flush();
  assert.equal(content.model.placement.width, 90);
  assert.equal(updated.offset.dx, 10);
  assert.equal(updated.offset.dy, 14);
  content.model.choose(0);
  assert.equal(await result, 0);
  assert.equal(sizeListener, undefined);
  assert.equal(closes, 1);
  assert.equal(disposed, 1);
});

test("the aggregate plugin manifest includes every standalone plugin", () => {
  const script = fs.readFileSync(path.join(root, "pack-plugins.ps1"), "utf8");
  const entries = [...script.matchAll(/name = '([^']+)';\s+cls = '([^']+)'/g)];
  const declared = new Set(entries.map((entry) => entry[1]));
  const actual = fs
    .readdirSync(path.join(root, "plugins"))
    .filter((name) => fs.existsSync(path.join(root, "plugins", name, "index.ets")));
  assert.deepEqual([...declared].sort(), actual.sort());
  for (const [, name, cls] of entries) {
    assert.ok(fs.existsSync(path.join(root, "plugins", name, "src/main/ets", cls + ".ets")));
  }
});

test("custom cursors validate their named contract before allocating native pixels", async () => {
  const { parseCustomCursor } = loader().load("plugins/window/src/main/ets/CustomCursor.ets");
  const value = { windowId: 0, width: 1, height: 1, hotspotX: 0, hotspotY: 0, rgba: [255, 0, 0, 128] };
  const payload = (v) => ({ typeName: "ohos.window.CustomCursorRequest", value: v });
  assert.equal(parseCustomCursor(payload(value)), value);
  for (const patch of [{ width: 0 }, { width: 257 }, { hotspotX: 1 }, { windowId: -1 }, { rgba: [0] }, { rgba: [0, 0, NaN, 0] }]) {
    assert.throws(() => parseCustomCursor(payload({ ...value, ...patch })), /Invalid/);
  }
  assert.throws(() => parseCustomCursor({ typeName: "std.string", value }), /requires/);
});

test("custom cursors release PixelMaps after success, OS failure and canceled calls", async () => {
  for (const outcome of ["success", "failure", "cancel"]) {
    let released = 0, installed = 0, active = true;
    const l = loader({
      "@kit.ImageKit": { image: {
        PixelMapFormat: { RGBA_8888: 3 }, AlphaType: { UNPREMUL: 3 },
        async createPixelMap(bytes, options) {
          assert.equal(bytes.byteLength, 4);
          assert.equal(options.alphaType, 3);
          assert.equal(options.srcPixelFormat, 3);
          if (outcome === "cancel") active = false;
          return { release() { released++; } };
        },
      } },
      "@ohos.multimodalInput.pointer": { async setCustomCursor(id, _pixels, x, y) {
        assert.equal(id, 42); assert.equal(x, 0); assert.equal(y, 0);
        installed++;
        if (outcome === "failure") throw new Error("OS rejected cursor");
      } },
    });
    const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
    const result = new WindowPlugin().invokeAsync("set-custom-cursor", {
      typeName: "ohos.window.CustomCursorRequest",
      value: { windowId: 0, width: 1, height: 1, hotspotX: 0, hotspotY: 0, rgba: [255, 0, 0, 128] },
    }, { isActive: () => active, getWindow: () => ({ getWindowProperties: () => ({ id: 42 }) }) });
    if (outcome === "success") assert.equal((await result).value.accepted, true);
    else await assert.rejects(result, outcome === "failure" ? /OS rejected/ : /no longer active/);
    assert.equal(released, 1, outcome);
    assert.equal(installed, outcome === "cancel" ? 0 : 1, outcome);
  }
});

test("window icons restore packaged pixels and reject unsupported devices without allocating", async () => {
  for (const device of ["phone", "2in1"]) {
    let released = 0, sources = 0, installed = 0;
    const pixels = { async release() { released++; } };
    const l = loader({
      "@kit.BasicServicesKit": { deviceInfo: { sdkApiVersion: 26, deviceType: device } },
      "@kit.ImageKit": { image: {
        PixelMapFormat: { RGBA_8888: 3 }, AlphaType: { UNPREMUL: 3 },
        async createPixelMap() { return pixels; },
        createImageSource() { return { async createPixelMap() { return pixels; }, async release() { sources++; } }; },
      } },
    });
    const { setWindowIcon } = l.load("plugins/window/src/main/ets/WindowIcon.ets");
    const context = { isActive: () => true, abilityContext: {
      abilityInfo: { iconId: 42 }, applicationInfo: { iconId: 43 },
      resourceManager: { async getMediaContent(id) { assert.equal(id, 42); return new Uint8Array([1]); } },
      async setMissionWindowIcon(value) { assert.equal(value, pixels); installed++; },
    } };
    const payload = (size, rgba) => ({ typeName: "ohos.window.WindowIconRequest", value: { windowId: 0, size, rgba } });
    for (const p of [payload(1, [0, 0, 255, 255]), payload(0, [])]) {
      if (device === "phone") await assert.rejects(setWindowIcon(p, context), /PC\/2in1/);
      else await setWindowIcon(p, context);
    }
    await assert.rejects(setWindowIcon(payload(2048, []), context), /Invalid/);
    assert.equal(installed, device === "phone" ? 0 : 2);
    assert.equal(released, installed);
    assert.equal(sources, device === "phone" ? 0 : 1);
  }
});
