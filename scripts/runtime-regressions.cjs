// Run with Node 22+ and OHOS_SDK_HOME pointing at the OpenHarmony SDK directory.
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
  WindowStatusType: { FULL_SCREEN: 1, MAXIMIZE: 2, MINIMIZE: 3, FLOATING: 4 },
  WindowEventType: { WINDOW_ACTIVE: 1, WINDOW_INACTIVE: 2, WINDOW_SHOWN: 3 },
  AvoidAreaType: { TYPE_SYSTEM: 0 },
  MaximizePresentation: { FOLLOW_APP_IMMERSIVE_SETTING: 0, EXIT_IMMERSIVE: 1, ENTER_IMMERSIVE: 2 },
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

function appControlPlugin() {
  return new (loader({
    "@ohos.process": {},
    "@ohos.app.ability.common": {},
    "@ohos-rs/ability": { ...base, SyncPluginBase: class {} },
  }).load("plugins/app-control/src/main/ets/AppControlPlugin.ets").AppControlPlugin)();
}

test("application restart targets its owning Ability through explicit restart", () => {
  const calls = [];
  const context = {
    isActive: () => true,
    abilityContext: {
      abilityInfo: { bundleName: "test.bundle", moduleName: "entry", name: "EditorAbility" },
      getApplicationContext: () => ({ restartApp: (want) => calls.push({ ...want }) }),
    },
  };
  const response = appControlPlugin().invokeSync("restart", {
    typeName: "ohos.app_control.RestartRequest", value: {},
  }, context);
  assert.deepEqual(calls, [{ bundleName: "test.bundle", moduleName: "entry", abilityName: "EditorAbility" }]);
  assert.equal(response.typeName, "ohos.app_control.RestartResponse");
  assert.equal(response.value.accepted, true);
});

test("application restart rejects inactive sessions and malformed requests before platform access", () => {
  const plugin = appControlPlugin();
  const context = {
    isActive: () => true,
    get abilityContext() { assert.fail("must not access the native context"); },
  };
  for (const payload of [
    { typeName: "std.bool", value: {} },
    { typeName: "ohos.app_control.RestartRequest", value: null },
    { typeName: "ohos.app_control.RestartRequest", value: true },
  ]) assert.throws(() => plugin.invokeSync("restart", payload, context), /requires bridge type/);
  context.isActive = () => false;
  assert.throws(() => plugin.invokeSync("restart", {
    typeName: "ohos.app_control.RestartRequest", value: {},
  }, context), /no longer active/);
});

test("application restart preserves platform failure instead of reporting success", () => {
  const failure = new Error("restart rate limit");
  failure.code = 16000064;
  const context = {
    isActive: () => true,
    abilityContext: {
      abilityInfo: { bundleName: "test.bundle", moduleName: "entry", name: "EditorAbility" },
      getApplicationContext: () => ({ restartApp() { throw failure; } }),
    },
  };
  assert.throws(() => appControlPlugin().invokeSync("restart", {
    typeName: "ohos.app_control.RestartRequest", value: {},
  }, context), (error) => error === failure);
});

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
    "@ohos.abilityAccessCtrl": { createAtManager() { assert.fail("unexpected permission request"); } },
    "@ohos.app.ability.common": {},
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
      (s) => !(ts.isFunctionDeclaration(s) && s.name?.text === "promptBuilder") && s.kind !== ts.SyntaxKind.StructDeclaration,
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
      DismissReason: { PRESS_BACK: 0, TOUCH_OUTSIDE: 1 },
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

test("native-only startup never loads the ArkWeb module", async () => {
  const nativeModule = {};
  const stored = new Map();
  const { ProcessInitializer } = loader({
    "../window/WindowManager": { WindowManager: { init() {}, getInstance: () => ({}) } },
    "../helper/loadable": { Loadable: {
      resolveModuleNames: () => ["zed"],
      load: async () => nativeModule,
    } },
  }, { AppStorage: { setOrCreate: (key, value) => stored.set(key, value) } })
    .load("native_ability/src/main/ets/ability/ProcessInitializer.ets");
  await ProcessInitializer.initialize({}, "zed", "async", {});
  assert.equal(ProcessInitializer.isInitialized(), true);
  assert.equal(ProcessInitializer.getNativeModules()[0], nativeModule);
  assert.equal(stored.size, 1);
});

test("custom protocols are registered before the deferred web engine initialization", async () => {
  const calls = [];
  const nativeModule = { registerCustomProtocol: () => calls.push("register-protocol") };
  const { ProcessInitializer } = loader({
    "../window/WindowManager": { WindowManager: { init() {}, getInstance: () => ({}) } },
    "../helper/loadable": { Loadable: {
      resolveModuleNames: () => ["web-example"],
      load: async () => nativeModule,
    } },
    "@ohos.web.webview": { WebviewController: {
      initializeWebEngine: () => calls.push("initialize-engine"),
    } },
  }, { AppStorage: { setOrCreate: () => calls.push("publish-module") } })
    .load("native_ability/src/main/ets/ability/ProcessInitializer.ets");
  await ProcessInitializer.initialize({}, "web-example", "async", {});
  await ProcessInitializer.initialize({}, "web-example", "async", {});
  assert.deepEqual(calls, ["register-protocol", "initialize-engine", "publish-module"]);
});

async function interactiveHost(operation, globals = {}) {
  const { BridgeHostRegistry } = loader({
    "@ohos.app.ability.common": {},
    "@ohos.arkui.node": {},
    "@ohos.arkui.UIContext": {},
    "@ohos.resourceManager": {},
    "../window/WindowManager": {},
  }, globals).load("native_ability/src/main/ets/bridge/BridgeHost.ets");
  const plugin = { id: "test.dialog", execution: "async", requires: ["ability"], invokeAsync: operation };
  const moduleName = "test-module";
  const sessionId = BridgeHostRegistry.prepare([moduleName], {}, [{ create: () => plugin }]);
  BridgeHostRegistry.configurePlugins(sessionId, moduleName, [{ id: plugin.id, execution: plugin.execution, requires: plugin.requires }]);
  await BridgeHostRegistry.activateAbility(sessionId, moduleName, { kind: "ability-create", payload: {} });
  return {
    invokeAsync: (...args) => BridgeHostRegistry.invokeAsync(sessionId, moduleName, ...args),
    beginClosing: () => BridgeHostRegistry.beginClosing(sessionId),
    dispose: () => BridgeHostRegistry.dispose(sessionId),
  };
}

test("interactive bridge calls keep waiting for the user without scheduling a deadline", async () => {
  const decision = deferred();
  const timers = new Set();
  let scheduledDeadlines = 0;
  const host = await interactiveHost(async (_action, _request, context) => {
    assert.equal(context.timeoutMs, 0);
    await decision.promise;
    return { typeName: "std.string", value: "selected" };
  }, {
    setTimeout(callback, timeout) {
      const timer = setTimeout(callback, timeout);
      timers.add(timer);
      scheduledDeadlines++;
      return timer;
    },
    clearTimeout(timer) { timers.delete(timer); clearTimeout(timer); },
  });
  const result = host.invokeAsync("test.dialog", "select", "std.string", "std.string", "", 0);
  await flush();
  // Plugin-install hooks retain their bounded deadlines; the pending dialog has none.
  assert.equal(timers.size, 0);
  const installedDeadlines = scheduledDeadlines;
  await flush();
  assert.equal(scheduledDeadlines, installedDeadlines);
  decision.resolve();
  assert.equal(await result, "selected");
  await host.dispose();
});

test("interactive bridge calls still cancel when their Ability session closes", async () => {
  const decision = deferred();
  let cancellationObserved = false;
  const host = await interactiveHost(async (_action, _request, context) => {
    context.onCancel(() => { cancellationObserved = true; });
    await decision.promise;
    return { typeName: "std.string", value: "stale" };
  });
  const result = host.invokeAsync("test.dialog", "select", "std.string", "std.string", "", 0);
  const rejected = assert.rejects(result, /closing/);
  await flush();
  host.beginClosing();
  await rejected;
  assert.equal(cancellationObserved, true);
  decision.resolve();
  await host.dispose();
});

test("ordinary bridge calls retain their timeout", async () => {
  const decision = deferred();
  const host = await interactiveHost(async () => {
    await decision.promise;
    return { typeName: "std.string", value: "late" };
  });
  await assert.rejects(host.invokeAsync("test.dialog", "select", "std.string", "std.string", "", 10), /timed out/);
  decision.resolve();
  await host.dispose();
});

function filesFor({ windows = new Map(), ready = Promise.resolve(), save = async () => [], api = 26 } = {}) {
  const constructions = [];
  const requests = [];
  const { FilesPlugin } = loader({
    "@ohos.app.ability.common": {},
    "@ohos.base": {},
    "@ohos.deviceInfo": { sdkApiVersion: api, deviceType: "2in1" },
    "@ohos-rs/ability": {
      ...base,
      WindowManager: { getInstance: () => ({
        waitForWindowCreation: () => ready,
        getWindow: (id) => windows.get(id),
      }) },
    },
    "@ohos.file.picker": {
      DocumentViewPicker: class {
        constructor(context, parent) { constructions.push({ context, parent }); }
        async save(options) { requests.push(options); return save(options); }
        async select(options) { requests.push(options); return []; }
        getSelectedIndex() { return -1; }
      },
      DocumentSaveOptions: class {},
      DocumentSelectOptions: class {},
      DocumentSelectMode: { FOLDER: 1 },
    },
  }, { canIUse: () => true }).load("plugins/files/src/main/ets/FilesPlugin.ets");
  const context = {
    abilityContext: {},
    isActive: () => true,
    isCancelled: () => false,
  };
  const invoke = (options = {}) => new FilesPlugin().invokeAsync("file-dialog", {
    typeName: "ohos.files.DialogOptions",
    value: { dialogType: "save-file", filters: [], allowMany: false, ...options },
  }, context);
  return { context, constructions, requests, invoke };
}

test("file picker preserves its requesting window while native creation is pending", async () => {
  const ready = deferred();
  const parentContext = {};
  const parent = { getUIContext: () => ({ getHostContext: () => parentContext }) };
  const windows = new Map();
  const files = filesFor({ windows, ready: ready.promise, save: async () => ["file://docs/saved.ts"] });
  const result = files.invoke({ parentWindowId: 7, suggestedName: "saved.ts" });
  await flush();
  assert.equal(files.constructions.length, 0);
  windows.set(7, parent);
  ready.resolve();
  const response = await result;
  assert.equal(response.typeName, "ohos.files.DialogResponse");
  assert.equal(response.value.files[0], "file://docs/saved.ts");
  assert.equal(files.constructions[0].parent, parent);
  assert.equal(files.constructions[0].context, parentContext);
  assert.equal(files.requests[0].newFileNames[0], "saved.ts");
});

test("file picker without an explicit window retains Ability behavior and user cancellation", async () => {
  const files = filesFor({ api: 12 });
  const result = await files.invoke();
  assert.equal(result.value.files.length, 0);
  assert.equal(files.constructions[0].context, files.context.abilityContext);
  assert.equal(files.constructions[0].parent, undefined);
});

test("file picker cannot appear in a different window after its parent closes or call is cancelled", async () => {
  for (const outcome of ["closed", "cancelled", "inactive"]) {
    const ready = deferred();
    const files = filesFor({ ready: ready.promise, windows: new Map([[0, {}]]) });
    const result = files.invoke({ parentWindowId: 7 });
    if (outcome === "cancelled") files.context.isCancelled = () => true;
    if (outcome === "inactive") files.context.isActive = () => false;
    ready.resolve();
    await assert.rejects(result, /no longer exists|cancelled/);
    assert.equal(files.constructions.length, 0);
  }
});

test("file picker rejects invalid parent IDs, unsupported APIs and stale completion", async () => {
  const files = filesFor();
  for (const parentWindowId of [-1, 1.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1, "7"]) {
    await assert.rejects(files.invoke({ parentWindowId }), /non-negative safe integer/);
  }
  await assert.rejects(filesFor({ api: 12 }).invoke({ parentWindowId: 0 }), /API 13/);
  const saved = deferred();
  const pending = filesFor({ save: () => saved.promise });
  const result = pending.invoke();
  pending.context.isCancelled = () => true;
  saved.resolve(["file://docs/stale.ts"]);
  await assert.rejects(result, /cancelled/);
});

const managerPath = "native_ability/src/main/ets/window/WindowManager.ets";
function managerFor(l = loader()) {
  const { WindowManager } = l.load(managerPath);
  WindowManager.init({});
  const manager = WindowManager.getInstance();
  l.imports["@ohos-rs/ability"].WindowManager = WindowManager;
  return { manager, l };
}

test("clipboard startup connects asynchronously before observing or writing", async () => {
  const connection = deferred();
  const events = [];
  let listener;
  const systemPasteboard = {
    hasData: () => connection.promise,
    on(_event, callback) { events.push("observe"); listener = callback; },
    off(_event, callback) { assert.equal(callback, listener); events.push("unsubscribe"); },
    async setData(data) { assert.equal(data, "copied text"); events.push("write"); },
  };
  const { ClipboardPlugin } = loader({
    "@ohos.pasteboard": {
      getSystemPasteboard: () => systemPasteboard,
      createData: (_type, text) => text,
    },
    "@kit.ArkTS": {},
  }).load("plugins/clipboard/src/main/ets/ClipboardPlugin.ets");
  const plugin = new ClipboardPlugin({ metadataMimeType: "application/x-test-metadata-v1" });
  const context = {
    isActive: () => true,
    invokeNativeSync(action, request, response) {
      assert.equal(action, "changed");
      assert.equal(request, "ohos.clipboard.ChangedEvent");
      assert.equal(response, "std.bool");
      events.push("changed");
    },
  };
  assert.equal(plugin.onInstall(context), undefined);
  const write = plugin.invokeAsync("write-text", {
    typeName: "ohos.clipboard.WriteTextRequest", value: { text: "copied text" },
  }, context);
  await flush();
  assert.deepEqual(events, []);
  connection.resolve(false);
  assert.equal((await write).value.accepted, true);
  listener();
  plugin.onDispose();
  plugin.onDispose();
  listener();
  assert.deepEqual(events, ["observe", "write", "changed", "unsubscribe"]);
});

test("clipboard connection failure or teardown cannot install a late listener or write", async () => {
  for (const outcome of ["failure", "dispose", "inactive"]) {
    const connection = deferred();
    let active = true;
    const { ClipboardPlugin } = loader({
      "@ohos.pasteboard": { getSystemPasteboard: () => ({
        hasData: () => connection.promise,
        on() { assert.fail("must not subscribe"); },
        off() { assert.fail("no listener was installed"); },
        setData() { assert.fail("must not write"); },
      }) },
      "@kit.ArkTS": {},
    }).load("plugins/clipboard/src/main/ets/ClipboardPlugin.ets");
    const plugin = new ClipboardPlugin({ metadataMimeType: "application/x-test-metadata-v1" });
    const context = { isActive: () => active };
    plugin.onInstall(context);
    const write = plugin.invokeAsync("write-text", {
      typeName: "ohos.clipboard.WriteTextRequest", value: { text: "cancelled" },
    }, context);
    const rejected = assert.rejects(write, outcome === "failure" ? /service unavailable/ : /no longer active/);
    if (outcome === "failure") connection.reject(new Error("service unavailable"));
    else {
      if (outcome === "dispose") plugin.onDispose();
      else active = false;
      connection.resolve(false);
    }
    await rejected;
    plugin.onDispose();
  }
});

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

function authorizedClipboardFor({ empty = false, temporary = false, failure, permission } = {}) {
  let granted = false;
  let active = true;
  let reads = 0;
  const calls = [];
  const owner = {};
  const data = (text) => ({
    getRecordCount: () => text ? 1 : 0,
    getRecordAt: () => ({ mimeType: "text", plainText: text, getValidTypes: () => [] }),
  });
  const { ClipboardPlugin } = loader({
    "@ohos.pasteboard": { MIMETYPE_TEXT_PLAIN: "text", getSystemPasteboard: () => ({
      hasData: async () => !empty,
      getData: async () => {
        reads++;
        if (failure && !granted) throw failure;
        return data(!empty && (granted || temporary) ? "authorized text" : undefined);
      },
    }) },
    "@kit.ArkTS": {},
    "@ohos.abilityAccessCtrl": { createAtManager: () => ({
      requestPermissionsFromUser: async (context, permissions) => {
        calls.push({ context, permissions });
        const result = permission ? await permission() : { authResults: [0] };
        granted = result.authResults?.[0] === 0;
        return result;
      },
    }) },
    "@ohos-rs/ability": { ...base, WindowManager: { getInstance: () => ({
      getFocusedWindow: () => ({ getUIContext: () => ({ getHostContext: () => owner }) }),
    }) } },
  }).load("plugins/clipboard/src/main/ets/ClipboardPlugin.ets");
  const plugin = new ClipboardPlugin({ metadataMimeType: "application/x-test-metadata-v1" });
  const context = { abilityContext: {}, isActive: () => active };
  const invoke = (action = "read-authorized-records", typeName = "ohos.clipboard.ReadAuthorizedRecordsRequest") => plugin.invokeAsync(action, { typeName, value: {} }, context);
  return { plugin, calls, owner, invoke, deactivate() { active = false; }, reads: () => reads };
}

test("explicit clipboard reads request permission from the focused Ability after denial", async () => {
  const state = authorizedClipboardFor();
  const response = await state.invoke();
  assert.equal(response.typeName, "ohos.clipboard.ReadRecordsResponse");
  assert.deepEqual(Array.from(response.value.records, (record) => record.text), ["authorized text"]);
  assert.equal(state.calls.length, 1);
  assert.equal(state.calls[0].context, state.owner);
  assert.deepEqual(Array.from(state.calls[0].permissions), ["ohos.permission.READ_PASTEBOARD"]);
  assert.equal(state.reads(), 2);
});

test("native temporary clipboard access and an empty board do not request permission", async () => {
  for (const options of [{ temporary: true }, { empty: true }]) {
    const state = authorizedClipboardFor(options);
    await state.invoke();
    assert.equal(state.calls.length, 0);
    assert.equal(state.reads(), 1);
  }
});

test("background clipboard reads never ask for permission", async () => {
  const state = authorizedClipboardFor();
  await assert.rejects(state.invoke("read-records", "ohos.clipboard.ReadTextRequest"), /unreadable/);
  assert.equal(state.calls.length, 0);
  assert.equal(state.reads(), 1);
});

test("clipboard user denial is returned instead of reading or reporting an empty board", async () => {
  for (const result of [{ authResults: [-1] }, { authResults: [] }]) {
    const state = authorizedClipboardFor({ permission: async () => result });
    await assert.rejects(state.invoke(), /Clipboard access was denied/);
    assert.equal(state.reads(), 1);
  }
});

test("concurrent explicit reads share one native clipboard permission request", async () => {
  const permission = deferred();
  const state = authorizedClipboardFor({ permission: () => permission.promise });
  const reads = [state.invoke(), state.invoke()];
  await flush();
  assert.equal(state.calls.length, 1);
  permission.resolve({ authResults: [0] });
  await Promise.all(reads);
  assert.equal(state.reads(), 4);
});

test("clipboard authorization cannot retry native reads after session teardown", async () => {
  for (const change of ["inactive", "dispose"]) {
    const permission = deferred();
    const state = authorizedClipboardFor({ permission: () => permission.promise });
    const pending = state.invoke();
    const rejected = assert.rejects(pending, /cancelled/);
    await flush();
    assert.equal(state.calls.length, 1);
    if (change === "inactive") state.deactivate();
    else state.plugin.onDispose();
    permission.resolve({ authResults: [0] });
    await rejected;
    assert.equal(state.reads(), 1);
  }
});

test("clipboard authorization retries native permission errors but preserves other failures", async () => {
  const denied = Object.assign(new Error("permission denied"), { code: 201 });
  const state = authorizedClipboardFor({ failure: denied });
  await state.invoke();
  assert.equal(state.calls.length, 1);
  const concurrent = authorizedClipboardFor({ failure: Object.assign(new Error("copy in progress"), { code: 27787277 }) });
  await assert.rejects(concurrent.invoke(), /copy in progress/);
  assert.equal(concurrent.calls.length, 0);
});

test("authorized clipboard reads validate their named request before reading", async () => {
  const state = authorizedClipboardFor();
  await assert.rejects(state.invoke("read-authorized-records", "ohos.clipboard.ReadTextRequest"));
  assert.equal(state.reads(), 0);
  assert.equal(state.calls.length, 0);
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

test("fullscreen restores the previous bounds or maximized mode after queued entry completes", async () => {
  for (const maximized of [false, true]) {
    const { manager, l } = managerFor();
    const entering = deferred();
    const events = [];
    const bounds = { left: 123, top: 234, width: 900, height: 700 };
    const win = {
      on() {},
      getWindowProperties: () => ({ windowRect: bounds }),
      getWindowStatus: () => maximized ? windowApi.WindowStatusType.MAXIMIZE : windowApi.WindowStatusType.FLOATING,
      async maximize(mode) {
        events.push(["maximize", mode]);
        if (mode === windowApi.MaximizePresentation.ENTER_IMMERSIVE) await entering.promise;
      },
      async recover() { events.push(["recover"]); },
      async setTitleAndDockHoverShown(title, dock) { events.push(["hover", title, dock]); },
      async resize(width, height) { events.push(["resize", width, height]); },
      async moveWindowTo(left, top) { events.push(["move", left, top]); },
    };
    manager.registerUIAbilityStage(0, { getMainWindowSync: () => win }, {});
    const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
    const plugin = new WindowPlugin();
    const payload = (on) => ({ typeName: "ohos.window.FullscreenRequest", value: { windowId: 0, on } });
    const context = { isActive: () => true };
    let acknowledged = false;
    const entry = plugin.invokeAsync("set-fullscreen", payload(true), context).then(() => { acknowledged = true; });
    await flush();
    const exit = plugin.invokeAsync("set-fullscreen", payload(false), context);
    await flush();
    assert.equal(acknowledged, false);
    assert.deepEqual(events, [["maximize", windowApi.MaximizePresentation.ENTER_IMMERSIVE]]);
    entering.resolve();
    await Promise.all([entry, exit]);
    assert.deepEqual(events, [
      ["maximize", windowApi.MaximizePresentation.ENTER_IMMERSIVE], ["hover", false, false], ["recover"],
      ...(maximized ? [["maximize", windowApi.MaximizePresentation.EXIT_IMMERSIVE]] : [["resize", 900, 700], ["move", 123, 234]]),
      ["hover", true, true],
    ]);
  }
});

test("fullscreen reports OS failures and skips canceled queued requests", async () => {
  const { manager, l } = managerFor();
  let active = true, attempts = 0;
  const win = {
    on() {},
    getWindowProperties: () => ({ windowRect: {} }),
    getWindowStatus: () => windowApi.WindowStatusType.FLOATING,
    async maximize() { attempts++; throw new Error("OS denied fullscreen"); },
  };
  manager.registerUIAbilityStage(0, { getMainWindowSync: () => win }, {});
  const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
  const plugin = new WindowPlugin();
  const request = () => plugin.invokeAsync("set-fullscreen", {
    typeName: "ohos.window.FullscreenRequest", value: { windowId: 0, on: true },
  }, { isActive: () => active });
  await assert.rejects(request(), /OS denied fullscreen/);
  const preceding = deferred();
  const queued = manager.serializeOp(0, () => preceding.promise);
  const canceled = assert.rejects(request(), /no longer active/);
  await flush();
  active = false;
  preceding.resolve();
  await Promise.all([queued, canceled]);
  assert.equal(attempts, 1);
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
  }, win);
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
  }, win);
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

test("focus activates visible and minimized children and overrides their creation focus policy", async () => {
  for (const initiallyVisible of [false, true]) {
    const { manager, l } = managerFor();
    const showing = deferred();
    let visible = initiallyVisible;
    let focused = false;
    let completed = false;
    const rect = { left: 250, top: 350, width: 1700, height: 1100 };
    const win = {
      isWindowShowing: () => visible,
      isFocused: () => focused,
      getWindowProperties: () => ({ windowRect: rect }),
      async showWindow(options) {
        assert.equal(options.focusOnShow, true);
        await showing.promise;
        visible = true;
        focused = true;
      },
      async raiseToAppTop() {},
      async recover() { assert.fail("activation must preserve the window mode"); },
      async moveWindowTo() { assert.fail("activation must preserve placement"); },
    };
    manager.windows.set(7, { window: win, focusOnShow: false });
    const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
    const result = new WindowPlugin().invokeAsync(
      "focus",
      { typeName: "ohos.window.WindowIdRequest", value: { windowId: 7 } },
      { isActive: () => true },
    ).then(() => { completed = true; });
    await flush();
    assert.equal(completed, false);
    assert.equal(focused, false);
    showing.resolve();
    await result;
    assert.equal(visible, true);
    assert.equal(focused, true);
    assert.deepEqual(rect, { left: 250, top: 350, width: 1700, height: 1100 });
  }
});

test("child activation supports showWindow before focusOnShow was introduced", async () => {
  const { manager, l } = managerFor(loader({ "@kit.BasicServicesKit": { deviceInfo: { sdkApiVersion: 19 } } }));
  let shown = false;
  manager.windows.set(7, { window: {
    async showWindow(options) {
      assert.equal(options, undefined);
      shown = true;
    },
    async raiseToAppTop() {},
  } });
  const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
  await new WindowPlugin().invokeAsync(
    "focus",
    { typeName: "ohos.window.WindowIdRequest", value: { windowId: 7 } },
    { isActive: () => true },
  );
  assert.equal(shown, true);
});

test("child activation reports the native show failure", async () => {
  const { manager, l } = managerFor();
  manager.windows.set(7, { window: {
    async showWindow() { throw new Error("OS show failure"); },
    async raiseToAppTop() {},
  } });
  const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
  await assert.rejects(new WindowPlugin().invokeAsync(
    "focus",
    { typeName: "ohos.window.WindowIdRequest", value: { windowId: 7 } },
    { isActive: () => true },
  ), /OS show failure/);
});

test("cancelled child activation does not acknowledge success", async () => {
  const { manager, l } = managerFor();
  let active = true;
  manager.windows.set(7, { window: {
    async showWindow() { active = false; },
    async raiseToAppTop() {},
  } });
  const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
  await assert.rejects(new WindowPlugin().invokeAsync(
    "focus",
    { typeName: "ohos.window.WindowIdRequest", value: { windowId: 7 } },
    { isActive: () => active },
  ), /no longer active/);
});

test("show retains pending placement, preserves focus policy and awaits platform completion", async () => {
  for (const focusOnShow of [true, false, undefined]) {
    const { manager, l } = managerFor();
    const showing = deferred();
    const requested = { left: 200, top: 350, width: 900, height: 700 };
    let rect = { left: 0, top: 0, width: 800, height: 600 };
    let completed = false;
    const win = {
      getWindowProperties: () => ({ windowRect: rect }),
      async showWindow(options) {
        assert.equal(options?.focusOnShow, focusOnShow);
        await showing.promise;
        rect = requested;
      },
      async moveWindowTo(left, top) {
        rect = { ...rect, left, top };
      },
    };
    manager.windows.set(7, { window: win, focusOnShow });
    const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
    const result = new WindowPlugin().invokeAsync(
      "show",
      { typeName: "ohos.window.WindowIdRequest", value: { windowId: 7 } },
      { isActive: () => true },
    ).then(() => { completed = true; });
    await flush();
    assert.equal(completed, false);
    showing.resolve();
    await result;
    assert.deepEqual(rect, requested);
  }
});

test("legacy sub-window show retains the OS-applied pending position", async () => {
  const { manager } = managerFor();
  const requested = { left: 0, top: 70, width: 2090, height: 1394 };
  let rect = { left: 0, top: 0, width: 800, height: 600 };
  manager.windows.set(7, { window: {
    getWindowProperties: () => ({ windowRect: rect }),
    async showWindow() { rect = requested; },
    async moveWindowTo(left, top) { rect = { ...rect, left, top }; },
  } });
  manager.showWindowMethod(7);
  await flush();
  assert.deepEqual(rect, requested);
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
      options.onWillDisappear();
      options.onDidDisappear();
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

function keyboardPrompt(
  initialActive,
  { deferredOpen = false, deferredClose = false, rejectFocus = false, rejectClose = false, anchor } = {},
) {
  let content,
    options,
    cancel,
    finishOpen,
    active = true;
  const events = [];
  const controller = {
    isActive: () => initialActive,
    activate: (value) => events.push(["activate", value]),
    requestFocus(componentId) {
      events.push(["focus", componentId]);
      if (rejectFocus) throw new Error("Native focus rejected");
    },
  };
  const ComponentContent = class {
    constructor(_ui, _builder, model) {
      this.model = model;
      content = this;
    }
    dispose() {
      events.push(["dispose"]);
    }
  };
  const prompt = {
    async openCustomDialog(_content, value) {
      options = value;
      if (deferredOpen)
        await new Promise((resolve) => {
          finishOpen = resolve;
        });
    },
    async closeCustomDialog() {
      events.push(["close"]);
      if (rejectClose) throw new Error("Native close rejected");
      options.onWillDisappear();
      if (!deferredClose) options.onDidDisappear();
    },
  };
  const uiContext = {
    px2vp: (value) => value,
    getPromptAction: () => prompt,
    getFocusController: () => controller,
  };
  const targetWindow = {
    getUIContext: () => uiContext,
    getWindowProperties: () => ({ windowRect: { width: 900, height: 700 } }),
    getWindowAvoidArea: () => ({
      leftRect: { width: 0 },
      rightRect: { width: 0 },
      topRect: { height: 0 },
      bottomRect: { height: 0 },
    }),
    on() {},
    off() {},
  };
  const { PromptDialogs } = loader({ "@kit.ArkUI": { window: windowApi, ComponentContent } }).load(
    "plugins/window/src/main/ets/PromptDialogs.ets",
  );
  const result = new PromptDialogs().show(
    targetWindow,
    { message: "Save?", level: 1, buttons: ["Save", "Cancel"], cancelIndex: 1, anchor },
    {
      isActive: () => active,
      onCancel(callback) {
        cancel = callback;
        return () => {};
      },
    },
  );
  result.catch(() => {});
  return {
    events,
    result,
    appear: () => options.onDidAppear(),
    willDisappear: () => options.onWillDisappear(),
    disappear: () => options.onDidDisappear(),
    choose: (index) => content.model.choose(index),
    cancel() {
      active = false;
      cancel();
    },
    finishOpen: () => finishOpen(),
    dismiss: (reason) => options.onWillDismiss({
      reason,
      dismiss: () => events.push(["dismiss"]),
    }),
  };
}

test("confirmation prompts ignore outside clicks but preserve Escape cancellation", async () => {
  const fixture = keyboardPrompt(false);
  let resolved = false;
  fixture.result.then(() => { resolved = true; });
  await flush();
  fixture.appear();
  fixture.dismiss(1);
  await flush();
  assert.equal(resolved, false);
  assert.equal(fixture.events.some(([event]) => event === "dismiss" || event === "close"), false);
  fixture.dismiss(0);
  assert.equal(await fixture.result, 1);
  assert.equal(fixture.events.filter(([event]) => event === "dismiss").length, 1);
  assert.equal(fixture.events.filter(([event]) => event === "dispose").length, 1);
});

test("anchored command prompts retain outside-click cancellation", async () => {
  const fixture = keyboardPrompt(false, { anchor: { x: 100, y: 100 } });
  await flush();
  fixture.appear();
  fixture.dismiss(1);
  assert.equal(await fixture.result, 1);
});

test("native prompts activate the default button only after appearance and restore prior keyboard focus", async () => {
  for (const initialActive of [false, true]) {
    const fixture = keyboardPrompt(initialActive);
    await flush();
    assert.deepEqual(fixture.events, []);
    fixture.appear();
    assert.deepEqual(fixture.events, [
      ["activate", true],
      ["focus", "native-window-prompt-0-0"],
    ]);
    fixture.choose(1);
    assert.equal(await fixture.result, 1);
    assert.deepEqual(fixture.events.slice(2), [
      ["close"],
      ["activate", initialActive],
      ["dispose"],
    ]);
    fixture.appear();
    assert.equal(fixture.events.length, 5);
  }
});

test("native prompt cancellation and focus failures preserve cleanup without late focus acquisition", async () => {
  for (const deferredOpen of [false, true]) {
    const fixture = keyboardPrompt(false, { deferredOpen });
    await flush();
    fixture.cancel();
    fixture.appear();
    if (deferredOpen) fixture.finishOpen();
    await assert.rejects(fixture.result, /cancelled/);
    assert.deepEqual(fixture.events, [["close"], ["dispose"]]);
  }
  const fixture = keyboardPrompt(false, { rejectFocus: true });
  await flush();
  fixture.appear();
  fixture.choose(1);
  assert.equal(await fixture.result, 1);
  assert.deepEqual(fixture.events.slice(2), [["close"], ["activate", false], ["dispose"]]);
});

test("native prompt choices and content disposal wait for the actual disappearance event", async () => {
  for (const index of [0, 1]) {
    const fixture = keyboardPrompt(false, { deferredClose: true });
    let resolved = false;
    fixture.result.then(() => {
      resolved = true;
    });
    await flush();
    fixture.appear();
    fixture.choose(index);
    await flush();
    assert.equal(resolved, false);
    assert.deepEqual(fixture.events.slice(2), [["close"]]);
    fixture.disappear();
    assert.equal(await fixture.result, index);
    assert.deepEqual(fixture.events.slice(2), [["close"], ["activate", false], ["dispose"]]);
  }
});

test("native prompt teardown releases a pending disappearance and failed closes cannot strand cleanup", async () => {
  const fixture = keyboardPrompt(false, { deferredClose: true });
  await flush();
  fixture.appear();
  fixture.choose(0);
  await flush();
  fixture.cancel();
  assert.equal(await fixture.result, 0);
  assert.deepEqual(fixture.events.slice(2), [["close"], ["dispose"]]);
  fixture.disappear();
  await flush();
  assert.deepEqual(fixture.events.slice(2), [["close"], ["dispose"]]);

  const failed = keyboardPrompt(false, { rejectClose: true });
  await flush();
  failed.appear();
  failed.choose(1);
  assert.equal(await failed.result, 1);
  assert.deepEqual(failed.events.slice(2), [["close"], ["activate", false], ["dispose"]]);
});

test("native prompts wait for an auto-dismiss already removed from the native registry", async () => {
  const fixture = keyboardPrompt(false, { rejectClose: true });
  let resolved = false;
  fixture.result.then(() => {
    resolved = true;
  });
  await flush();
  fixture.appear();
  fixture.willDisappear();
  fixture.choose(1);
  await flush();
  assert.equal(resolved, false);
  assert.deepEqual(fixture.events.slice(2), [["close"]]);
  fixture.disappear();
  assert.equal(await fixture.result, 1);
  assert.deepEqual(fixture.events.slice(2), [["close"], ["activate", false], ["dispose"]]);
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
    const { manager } = managerFor(l);
    const win = { on() {}, getWindowProperties: () => ({ id: 42 }), getUIContext: () => ({ getHostContext: () => ({}) }) };
    manager.registerUIAbilityStage(0, { getMainWindowSync: () => win }, {});
    const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
    const result = new WindowPlugin().invokeAsync("set-custom-cursor", {
      typeName: "ohos.window.CustomCursorRequest",
      value: { windowId: 0, width: 1, height: 1, hotspotX: 0, hotspotY: 0, rgba: [255, 0, 0, 128] },
    }, { isActive: () => active, getWindow: () => win });
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


test("pointer visibility waits for native completion and propagates failures", async () => {
  for (const outcome of ["success", "failure", "cancel"]) {
    const operation = deferred();
    let active = true, settled = false;
    const calls = [];
    const runtime = loader({
      "@ohos.multimodalInput.pointer": {
        setPointerVisible(visible) {
          calls.push(visible);
          return operation.promise;
        },
      },
    });
    managerFor(runtime);
    const { WindowPlugin } = runtime.load("plugins/window/src/main/ets/WindowPlugin.ets");
    const result = new WindowPlugin().invokeAsync("set-cursor-visible", {
      typeName: "ohos.window.CursorVisibleRequest", value: { visible: false },
    }, { isActive: () => active });
    result.then(() => { settled = true; }, () => { settled = true; });
    await flush();
    assert.deepEqual(calls, [false]);
    assert.equal(settled, false, "native visibility is still pending");
    if (outcome === "failure") operation.reject(new Error("pointer service unavailable"));
    else {
      if (outcome === "cancel") active = false;
      operation.resolve();
    }
    if (outcome === "success") {
      const response = await result;
      assert.equal(response.typeName, "ohos.window.Acknowledgement");
      assert.equal(response.value.accepted, true);
    } else {
      await assert.rejects(result, outcome === "failure" ? /service unavailable/ : /no longer active/);
    }
  }
});

test("pointer visibility validates the named request before invoking the platform", async () => {
  let calls = 0;
  const runtime = loader({
    "@ohos.multimodalInput.pointer": { async setPointerVisible() { calls++; } },
  });
  managerFor(runtime);
  const { WindowPlugin } = runtime.load("plugins/window/src/main/ets/WindowPlugin.ets");
  const plugin = new WindowPlugin();
  for (const payload of [
    { typeName: "std.bool", value: false },
    { typeName: "ohos.window.CursorVisibleRequest", value: { visible: "false" } },
  ]) {
    await assert.rejects(plugin.invokeAsync("set-cursor-visible", payload, { isActive: () => true }), /requires/);
  }
  assert.equal(calls, 0);
});


test("unsupported pointer visibility is rejected without masking other platform errors", async () => {
  for (const code of [801, 201, 401]) {
    const runtime = loader({
      "@ohos.multimodalInput.pointer": {
        async setPointerVisible() { throw Object.assign(new Error("native pointer failure"), { code }); },
      },
    });
    managerFor(runtime);
    const { WindowPlugin } = runtime.load("plugins/window/src/main/ets/WindowPlugin.ets");
    const result = new WindowPlugin().invokeAsync("set-cursor-visible", {
      typeName: "ohos.window.CursorVisibleRequest", value: { visible: false },
    }, { isActive: () => true });
    if (code === 801) {
      const response = await result;
      assert.equal(response.typeName, "ohos.window.Acknowledgement");
      assert.equal(response.value.accepted, false);
    } else await assert.rejects(result, /native pointer failure/);
  }
});


test("system termination defers to the live main-window close handler", () => {
  const runtime = loader({
    "@kit.AbilityKit": { UIAbility: class {} },
    "@ohos.app.ability.common": {},
    "../components/MainPage": {},
    "../bridge/BridgeHost": {},
    "../runtime/NativeModuleLoader": {},
    "../runtime/AbilityStateCodec": {},
    "./type": {},
    "./ProcessInitializer": {},
    "../helper/constants": { DOMAIN: 0, MAIN_WINDOW_ID: 0 },
  });
  const { manager } = managerFor(runtime);
  const { NativeAbility } = runtime.load("native_ability/src/main/ets/ability/NativeAbility.ets");
  const ability = new NativeAbility();
  const requests = [];
  const removeClose = manager.registerCloseRequestInterceptor((windowId) => { requests.push(windowId); return true; });
  assert.equal(ability.onPrepareToTerminate(), false, "before an active session there is no app window to close");
  ability.acceptingLifecycle = true;
  ability.windowStageActive = true;
  assert.equal(ability.onPrepareToTerminate(), true, "defer synchronously before the OS destroys the Ability");
  assert.deepEqual(requests, [0]);
  removeClose();
  assert.equal(ability.onPrepareToTerminate(), false, "an app without a close handler retains system behavior");
  manager.registerCloseRequestInterceptor(() => { throw new Error("must not route into an inactive session"); });
  ability.windowStageActive = false;
  assert.equal(ability.onPrepareToTerminate(), false);
  ability.windowStageActive = true;
  ability.acceptingLifecycle = false;
  assert.equal(ability.onPrepareToTerminate(), false);
});

function abilityWindowRuntime({ start, initialized = true, globals = {} } = {}) {
  const closed = [], started = [], nativeClosed = [], notifiedModules = [];
  const runtime = loader({
    "@kit.AbilityKit": { UIAbility: class {} },
    "@kit.BasicServicesKit": { deviceInfo: { sdkApiVersion: 26, deviceType: "2in1" } },
    "./ProcessInitializer": { ProcessInitializer: { isInitialized: () => initialized } },
    "../runtime/NativeModuleLoader": { NativeModuleLoader: { getLoadedModule: (moduleName) => ({
      notifyNativeWindowClose(id) { nativeClosed.push(id); notifiedModules.push(moduleName); },
      notifyWindowClose() {},
    }) } },
    "./type": {},
    "../helper/constants": { DOMAIN: 0, MAIN_WINDOW_ID: 0, NATIVE_MODULE_STORAGE_KEY: "native" },
  }, {
    AppStorage: { get: () => ({
      notifyNativeWindowClose(id) { nativeClosed.push(id); },
      notifyWindowClose() {},
    }) },
    ...globals,
  });
  const { manager } = managerFor(runtime);
  const { NativeWindowAbility } = runtime.load("native_ability/src/main/ets/ability/NativeWindowAbility.ets");
  manager.context = {
    abilityInfo: { bundleName: "test.app", moduleName: "entry" },
    async startAbility(want, options) { started.push({ want, options }); await start?.(want); },
    async terminateSelf() { closed.push(0); },
  };
  manager.registerUIAbilityStage(0, { getMainWindowSync: () => ({ on() {}, off() {} }) }, manager.context);
  manager.setIndependentWindowAbility("WorkspaceAbility");
  function attach(id, phase, loading, resizing) {
    const handlers = new Map(), subscriptions = [];
    const calls = [], geometry = [];
    const win = {
      async setWindowBackgroundColor(color) { geometry.push(["background", color]); },
      on(name, listener) { handlers.set(name, listener); subscriptions.push(name); },
      off(name, listener) { assert.equal(handlers.get(name), listener); handlers.delete(name); },
      async loadContentByName() { if (loading) await loading; if (phase === "load") throw new Error(phase); },
      getUIContext: () => ({}),
      getWindowStatus: () => windowApi.WindowStatusType.FLOATING,
      async resize() { calls.push("resize"); if (resizing) await resizing; if (phase === "resize") throw new Error(phase); },
      async moveWindowTo() { if (phase === "move") throw new Error(phase); },
      async showWindow(options) { calls.push("show"); assert.equal(options?.focusOnShow, false, "explicit show requests retain the requested focus policy"); if (phase === "show") throw new Error(phase); },
    };
    const ability = new NativeWindowAbility();
    ability.context = {
      ...manager.context,
      currentHapModuleInfo: { mainElementName: "EntryAbility" },
      async terminateSelf() { closed.push(id); ability.onWindowStageDestroy(); },
    };
    ability.onCreate({ parameters: { "openharmony.ability.windowId": id } });
    ability.onWindowStageCreate({ getMainWindowSync: () => win });
    return { ability, win, handlers, subscriptions, calls, geometry };
  }
  const options = (id) => ({ windowId: id, name: `workspace-${id}`, independent: true, nativeModuleName: "zed", show: true, focus: false });
  return { runtime, manager, NativeWindowAbility, options, attach, started, closed, nativeClosed, notifiedModules };
}

test("independent workspaces share the process and close only their own Ability", async () => {
  const state = abilityWindowRuntime();
  const first = state.manager.createSubWindow(state.options(7));
  const second = state.manager.createSubWindow(state.options(9));
  await flush();
  const window9 = state.attach(9), window7 = state.attach(7);
  assert.deepEqual(await Promise.all([first, second]), [7, 9]);
  assert.equal(state.manager.getWindow(7), window7.win);
  assert.equal(state.manager.getWindow(9), window9.win);
  assert.equal(state.manager.windows.get(9).storage.get("decorations"), false, "main windows use their native decoration API without a second title bar");
  assert.deepEqual(state.started.map(({ want }) => want.abilityName), ["WorkspaceAbility", "WorkspaceAbility"]);
  for (const instance of [window7, window9]) {
    assert.equal(instance.subscriptions.filter((name) => name === "windowEvent").length, 1);
  }
  const closeRequests = [];
  state.manager.registerCloseRequestInterceptor((id) => { closeRequests.push(id); return true; });
  assert.equal(window9.ability.onPrepareToTerminate(), true);
  assert.equal(window7.ability.onPrepareToTerminate(), true);
  assert.deepEqual(closeRequests, [9, 7]);
  await state.manager.destroyWindow(9);
  window9.ability.onDestroy();
  assert.deepEqual(state.closed, [9]);
  assert.deepEqual(state.nativeClosed, [9]);
  assert.equal(state.manager.getWindow(9), undefined);
  assert.equal(state.manager.getWindow(7), window7.win);
  assert.equal(window9.handlers.size, 0);
  assert.equal(window9.ability.onPrepareToTerminate(), false);
  assert.equal(window7.ability.onPrepareToTerminate(), true);
});

test("a destroyed workspace rejects creation without waiting for a pending native setter", async () => {
  const resizing = deferred();
  const state = abilityWindowRuntime();
  const creation = state.manager.createSubWindow(state.options(7));
  const rejected = assert.rejects(creation, /creation was canceled/);
  let failed = false;
  creation.catch(() => { failed = true; });
  const instance = state.attach(7, undefined, undefined, resizing.promise);
  await flush();
  assert.deepEqual(instance.calls, ["resize"]);
  await state.manager.destroyWindow(7);
  try {
    await flush();
    assert.equal(failed, true, "native teardown must reject creation even while a setter is pending");
  } finally {
    resizing.resolve();
    await rejected;
  }
  await flush();
  assert.deepEqual(instance.calls, ["resize"], "the late setter cannot show a destroyed window");
  assert.equal(state.manager.getWindow(7), undefined);
  assert.equal(state.manager.pendingAbilityWindows.size, 0);
  assert.equal(state.manager.isUIAbilityMainWindow(0), true);
});

test("a workspace destroyed after content readiness cannot finish a pending Ability launch", async () => {
  const launch = deferred();
  const state = abilityWindowRuntime({ start: () => launch.promise });
  const creation = state.manager.createSubWindow(state.options(7));
  const rejected = assert.rejects(creation, /creation was canceled/);
  let failed = false;
  creation.catch(() => { failed = true; });
  const instance = state.attach(7);
  await flush();
  assert.equal(state.manager.getWindow(7), instance.win);
  instance.ability.onWindowStageDestroy();
  try {
    await flush();
    assert.equal(failed, true, "content readiness must not settle creation before the native launch finishes");
  } finally {
    launch.resolve();
    await rejected;
  }
  assert.equal(state.manager.getWindow(7), undefined);
  assert.equal(state.manager.pendingAbilityWindows.size, 0);
  assert.equal(state.manager.isUIAbilityMainWindow(0), true);
});

test("independent workspace creation failures propagate and release only that window", async () => {
  for (const phase of ["start", "load", "resize", "move", "show"]) {
    const state = abilityWindowRuntime({ start: async () => { if (phase === "start") throw new Error(phase); } });
    const creation = state.manager.createSubWindow({ ...state.options(7), show: true });
    const rejected = assert.rejects(creation, new RegExp(phase));
    const instance = phase === "start" ? undefined : state.attach(7, phase);
    await rejected;
    await flush();
    assert.equal(state.manager.getWindow(7), undefined, phase);
    assert.equal(state.manager.getUIContext(7), undefined, phase);
    assert.equal(state.manager.pendingAbilityWindows.size, 0, phase);
    assert.equal(state.manager.creatingWindows.size, 0, phase);
    assert.equal(state.manager.isUIAbilityMainWindow(0), true, phase);
    assert.deepEqual(state.closed, phase === "start" ? [] : [7], phase);
    if (instance) assert.equal(instance.handlers.size, 0, phase);
  }
});

test("an expired workspace launch cannot attach a late native window", async () => {
  let timeout, cleared = 0;
  const state = abilityWindowRuntime({ globals: {
    setTimeout(callback) { timeout = callback; return 1; },
    clearTimeout(id) { assert.equal(id, 1); cleared++; },
  } });
  const rejected = assert.rejects(state.manager.createSubWindow(state.options(7)), /Timed out/);
  timeout();
  await rejected;
  assert.equal(cleared, 1);
  assert.equal(state.manager.pendingAbilityWindows.size, 0);
  await assert.rejects(state.manager.attachAbilityWindow(7, {}, {}), /No pending creation/);
  assert.equal(state.manager.getWindow(7), undefined);
});

test("a cold workspace launch restores the entry Ability instead of initializing another Rust app", async () => {
  const state = abilityWindowRuntime({ initialized: false });
  const ability = new state.NativeWindowAbility();
  ability.context = {
    ...state.manager.context,
    currentHapModuleInfo: { mainElementName: "EntryAbility" },
    async terminateSelf() { state.closed.push(7); },
  };
  ability.onCreate({ parameters: { "openharmony.ability.windowId": 7, document: "fixture" }, uri: "test://document" });
  ability.onWindowStageCreate({});
  await flush();
  assert.deepEqual(state.started.map(({ want }) => want.abilityName), ["EntryAbility"]);
  assert.equal(state.started[0].want.parameters.document, "fixture");
  assert.equal(state.started[0].want.uri, "test://document");
  assert.deepEqual(state.closed, [7]);
  assert.equal(ability.onPrepareToTerminate(), false);
  assert.equal(state.manager.isUIAbilityMainWindow(0), true);
});

test("canceled workspace loading cannot reattach a UI context after termination", async () => {
  let timeout;
  const loading = deferred();
  const state = abilityWindowRuntime({ globals: {
    setTimeout(callback) { timeout = callback; return 1; },
    clearTimeout() {},
  } });
  const rejected = assert.rejects(state.manager.createSubWindow(state.options(7)), /Timed out/);
  state.attach(7, undefined, loading.promise);
  timeout();
  await rejected;
  loading.resolve();
  await flush();
  assert.equal(state.manager.getWindow(7), undefined);
  assert.equal(state.manager.getUIContext(7), undefined);
  assert.deepEqual(state.closed, [7]);
});


test("a destroyed workspace stage cannot finish its pending content attachment", async () => {
  const loading = deferred();
  const state = abilityWindowRuntime();
  const rejected = assert.rejects(state.manager.createSubWindow(state.options(7)), /creation was canceled/);
  const instance = state.attach(7, undefined, loading.promise);
  instance.ability.onWindowStageDestroy();
  loading.resolve();
  await rejected;
  await flush();
  assert.equal(state.manager.getWindow(7), undefined);
  assert.equal(state.manager.getUIContext(7), undefined);
  assert.equal(state.manager.pendingAbilityWindows.size, 0);
  assert.equal(instance.handlers.size, 0);
  assert.equal(state.manager.isUIAbilityMainWindow(0), true);
});


test("the destroy-window bridge terminates only the requested workspace Ability", async () => {
  const state = abilityWindowRuntime();
  const creation = state.manager.createSubWindow(state.options(7));
  const instance = state.attach(7);
  await creation;
  const { WindowPlugin } = state.runtime.load("plugins/window/src/main/ets/WindowPlugin.ets");
  const plugin = new WindowPlugin();
  const payload = { typeName: "ohos.window.WindowIdRequest", value: { windowId: 7 } };
  const context = { isActive: () => true };
  await assert.rejects(plugin.invokeAsync("destroy-window", payload, { isActive: () => false }), /no longer active/);
  assert.deepEqual(state.closed, []);
  const response = await plugin.invokeAsync("destroy-window", payload, context);
  assert.equal(response.typeName, "ohos.window.Acknowledgement");
  assert.equal(response.value.accepted, true);
  await plugin.invokeAsync("destroy-window", payload, context);
  assert.deepEqual(state.closed, [7]);
  assert.equal(instance.handlers.size, 0);
  assert.equal(state.manager.getWindow(7), undefined);
  assert.equal(state.manager.isUIAbilityMainWindow(0), true);
  await assert.rejects(plugin.invokeAsync("destroy-window", {
    typeName: "ohos.window.WindowIdRequest", value: { windowId: 0 },
  }, context), /Cannot destroy the main Ability window/);
});


test("hidden workspaces defer native launch until an explicit show or focus request", async () => {
  for (const action of ["show", "focus", "restore"]) {
    const state = abilityWindowRuntime();
    const creation = state.manager.createSubWindow({ ...state.options(7), show: false });
    await flush();
    assert.equal(state.started.length, 0, "hidden creation must not foreground another Ability");
    assert.equal(state.manager.hasPendingAbilityWindow(7), false);
    const { WindowPlugin } = state.runtime.load("plugins/window/src/main/ets/WindowPlugin.ets");
    const plugin = new WindowPlugin();
    const payload = { typeName: "ohos.window.WindowIdRequest", value: { windowId: 7 } };
    await assert.rejects(plugin.invokeAsync(action, payload, { isActive: () => false }), /no longer active/);
    assert.equal(state.started.length, 0, "an expired caller cannot launch a deferred window");
    const restored = [];
    state.manager.restoreWindow = async (id, options) => restored.push({ id, focus: options.focus });
    const showing = plugin.invokeAsync(action, payload, { isActive: () => true });
    const showingAgain = plugin.invokeAsync(action, payload, { isActive: () => true });
    await flush();
    assert.equal(state.started.length, 1, "concurrent visibility requests launch once");
    state.attach(7);
    assert.equal(await creation, 7);
    await Promise.all([showing, showingAgain]);
    assert.deepEqual(restored.map((request) => request.id), [7, 7]);
    assert.equal(restored[0].focus, action === "focus" ? true : undefined);
  }
});

test("closing a never-shown workspace releases its waiters without launching an Ability", async () => {
  const state = abilityWindowRuntime({ globals: {
    setTimeout() { throw new Error("hidden windows must not start a native creation timeout"); },
  } });
  const creation = state.manager.createSubWindow({ ...state.options(7), show: false });
  await flush();
  const { WindowPlugin } = state.runtime.load("plugins/window/src/main/ets/WindowPlugin.ets");
  const plugin = new WindowPlugin();
  const payload = { typeName: "ohos.window.WindowIdRequest", value: { windowId: 7 } };
  const waiting = assert.rejects(plugin.invokeAsync("is-maximized", payload, { isActive: () => true }), /not ready/);
  const closing = plugin.invokeAsync("destroy-window", payload, { isActive: () => true });
  await Promise.all([creation, waiting, closing]);
  await plugin.invokeAsync("destroy-window", payload, { isActive: () => true });
  assert.equal(state.started.length, 0);
  assert.equal(state.manager.creatingWindows.size, 0);
  assert.equal(state.manager.isWindowCreationDeferred(7), false);
  assert.equal(state.manager.pendingAbilityWindows.size, 0);
  assert.equal(state.manager.isUIAbilityMainWindow(0), true);
});

test("stack queries skip never-shown workspaces without launching or waiting for them", async () => {
  const state = abilityWindowRuntime();
  windowApi.getWindowsByCoordinate = async () => [];
  const creation = state.manager.createSubWindow({ ...state.options(7), show: false });
  const { WindowPlugin } = state.runtime.load("plugins/window/src/main/ets/WindowPlugin.ets");
  const plugin = new WindowPlugin();
  const result = await plugin.invokeAsync("get-window-stack", {
    typeName: "ohos.window.StackRequest", value: { displayId: 0, windowIds: [7] },
  }, { isActive: () => true });
  assert.deepEqual(Array.from(result.value.windowIds), []);
  assert.equal(state.started.length, 0);
  state.manager.cancelDeferredWindowCreation(7);
  await creation;
});


test("a deferred native launch failure rejects visibility and releases creation state", async () => {
  const state = abilityWindowRuntime({ start: async () => { throw new Error("launch rejected"); } });
  const creation = state.manager.createSubWindow({ ...state.options(7), show: false });
  const rejected = assert.rejects(creation, /launch rejected/);
  const { WindowPlugin } = state.runtime.load("plugins/window/src/main/ets/WindowPlugin.ets");
  const plugin = new WindowPlugin();
  await assert.rejects(plugin.invokeAsync("focus", {
    typeName: "ohos.window.WindowIdRequest", value: { windowId: 7 },
  }, { isActive: () => true }), /launch rejected/);
  await rejected;
  assert.equal(state.manager.isWindowCreationDeferred(7), false);
  assert.equal(state.manager.creatingWindows.size, 0);
  assert.equal(state.manager.pendingAbilityWindows.size, 0);
  assert.equal(state.manager.getWindow(7), undefined);
  assert.equal(state.manager.isUIAbilityMainWindow(0), true);
});


test("tearing down the primary stage cancels all never-shown workspace requests", async () => {
  const state = abilityWindowRuntime();
  const creations = [7, 9].map((id) => state.manager.createSubWindow({ ...state.options(id), show: false }));
  state.manager.unregisterUIAbilityStage(0);
  await Promise.all(creations);
  assert.equal(state.started.length, 0);
  assert.equal(state.manager.deferredAbilityWindows.size, 0);
  assert.equal(state.manager.creatingWindows.size, 0);
  state.manager.startDeferredWindowCreation(7);
  await flush();
  assert.equal(state.started.length, 0, "a stale visibility request cannot launch after teardown");
});

function permissionsFor(focusedWindow, request = async () => ({ authResults: [0] })) {
  const calls = [];
  const { PermissionPlugin } = loader({
    "@ohos.app.ability.common": {},
    "@ohos.hilog": quietConsole,
    "@ohos.abilityAccessCtrl": { createAtManager: () => ({
      requestPermissionsFromUser: async (context, permissions) => {
        calls.push({ context, permissions });
        return request();
      },
    }) },
    "@ohos-rs/ability": { ...base, WindowManager: { getInstance: () => ({ getFocusedWindow: () => focusedWindow }) } },
  }).load("plugins/permission/src/main/ets/PermissionPlugin.ets");
  const context = { abilityContext: {}, isActive: () => true };
  const invoke = () => new PermissionPlugin().invokeAsync("request", {
    typeName: "ohos.permission.PermissionRequest",
    value: { permissions: ["ohos.permission.MICROPHONE"] },
  }, context);
  return { context, calls, invoke };
}

test("permission dialogs belong to the focused independent Ability", async () => {
  const owner = {};
  const permissions = permissionsFor({ getUIContext: () => ({ getHostContext: () => owner }) });
  const response = await permissions.invoke();
  assert.equal(permissions.calls[0].context, owner);
  assert.equal(response.typeName, "ohos.permission.PermissionResponse");
  assert.deepEqual(Array.from(response.value.codes), [0]);
});

test("permission requests without a window retain the session Ability", async () => {
  const permissions = permissionsFor(null, async () => ({ authResults: [-1] }));
  const response = await permissions.invoke();
  assert.equal(permissions.calls[0].context, permissions.context.abilityContext);
  assert.deepEqual(Array.from(response.value.codes), [-1]);
});

test("permission failure and session teardown do not grant microphone access", async () => {
  const inactive = permissionsFor(null);
  inactive.context.isActive = () => false;
  await assert.rejects(inactive.invoke(), /no longer active/);
  assert.equal(inactive.calls.length, 0);
  const failed = permissionsFor(null, async () => { throw new Error("native failure"); });
  assert.deepEqual(Array.from((await failed.invoke()).value.codes), [-1]);
  const pending = deferred();
  const disposed = permissionsFor(null, () => pending.promise);
  const result = disposed.invoke();
  disposed.context.isActive = () => false;
  pending.resolve({ authResults: [0] });
  await assert.rejects(result, /destroyed/);
});


function menuRuntime() {
  const stored = new Map(), windows = new Map(), events = [];
  const globals = { KeyType: { Down: 0, Up: 1 }, AppStorage: {
    get: key => stored.get(key), setOrCreate: (key, value) => stored.set(key, value),
  } };
  const l = loader({ "@kit.InputKit": { KeyCode: { KEYCODE_ESCAPE: 2070 } },
    "@ohos.web.webview": {}, "@ohos.app.ability.common": {},
  }, globals);
  const slots = l.load("native_ability/src/main/ets/components/MenuBarSlot.ets");
  const registry = l.load("plugins/menu/src/main/ets/MenuWindowRegistry.ets");
  const matchers = l.load("plugins/menu/src/main/ets/accelerator_matcher.ets");
  Object.assign(l.imports["@ohos-rs/ability"], slots, {
    MAIN_WINDOW_ID: 0,
    hasWebviewKeyboardPolicy: () => false,
    setPrimaryWebviewControllerCallback: () => () => {},
    WindowManager: { getInstance: () => ({
      getWindow: id => windows.get(id), getUserInteractedWindow: () => null,
      getFocusedWindow: () => null, getWebviewController: () => undefined,
    }) },
  });
  l.imports["./MenuBarComponent"] = registry;
  const { MenuPlugin } = l.load("plugins/menu/src/main/ets/MenuPlugin.ets");
  function host(id, options = {}) {
    const win = windows.get(id) ?? { getWindowProperties: () => ({ id }), getUIContext: () => ({ getHostContext: () => ({}) }) };
    windows.set(id, win);
    const cancellations = new Set();
    let active = true;
    const context = { abilityContext: {}, getWindow: () => win,
      isActive: () => active, isCancelled: () => !active,
      onCancel(fn) { cancellations.add(fn); return () => cancellations.delete(fn); },
      invokeNativeSync: (...args) => events.push([id, ...args]),
      invokeNativeSyncProcessWide() { assert.fail("window menu events must not broadcast"); },
    };
    const plugin = new MenuPlugin(options);
    plugin.onInstall(context);
    return { plugin, context, win, key: `native:${id}`,
      cancel() { active = false; for (const fn of cancellations) fn(); },
      invoke(action, value, type) { return plugin.invokeAsync(action, { typeName: `ohos.menu.${type}`, value }, context); },
    };
  }
  return { slots, registry, matchers, host, windows, events, l };
}

test("native applications can retain contextual keyboard shortcuts with rendered menus", () => {
  const runtime = menuRuntime();
  for (const [id, enabled] of [[1, undefined], [2, true], [3, false]]) {
    const host = runtime.host(id, { handleKeyboardShortcuts: enabled });
    const matcher = runtime.matchers.getAcceleratorMatcher(host.key);
    matcher.matches = () => true;
    matcher.getMatchedItem = () => ({ id: "close-window", type: "item" });
    const port = runtime.slots.getMenuBarPort(host.win);
    const before = runtime.events.length;
    assert.equal(port.onKeyPreIme({ type: 0, keyCode: 2039 }, 0), enabled !== false);
    assert.equal(runtime.events.length - before, enabled === false ? 0 : 1);
    assert.equal(port.onKeyPreIme({ type: 1, keyCode: 2039 }, 0), false);
  }
});

test("native application menu popups retain window routing without a separate menu row", async () => {
  const runtime = menuRuntime(), calls = [];
  const host = runtime.host(1, { showMenuBar: false, handleKeyboardShortcuts: false });
  runtime.windows.set(42, { getWindowProperties: () => ({ id: 42 }), getUIContext: () => ({ getHostContext: () => ({}) }) });
  runtime.registry.registerMenuDataCallback("native:42", {
    onApplicationMenu: (...args) => calls.push(["42", ...args]),
  });
  assert.equal(runtime.slots.getMenuBarSlotBuilder(host.win).name, "menuPopupBuilder");
  const invoke = value => host.invoke("popup-menubar", value, "PopupMenubarRequest");
  const result = await invoke({ windowId: "42", menuName: "File", x: 16, y: 30 });
  assert.equal(result.typeName, "ohos.menu.Acknowledgement");
  assert.equal(result.value.accepted, true);
  assert.equal(runtime.slots.getMenuBarSlotBuilder(runtime.windows.get(42)).name, "menuPopupBuilder");
  await invoke({ windowId: "42", x: 17, y: 31 });
  await invoke({ windowId: "42", x: 18, y: 32, restoreFocusId: "editor-42" });
  assert.deepEqual(calls, [["42", "File", 16, 30, undefined], ["42", undefined, 17, 31, undefined],
    ["42", undefined, 18, 32, "editor-42"]]);
  for (const restoreFocusId of ["", " ", 42]) {
    await assert.rejects(invoke({ windowId: "42", x: 0, y: 0, restoreFocusId }));
  }
  await assert.rejects(invoke({ windowId: "missing", x: 0, y: 0 }), /No menu window/);
  await assert.rejects(invoke({ windowId: "42", x: NaN, y: 0 }), /finite position/);
  await assert.rejects(invoke({ windowId: "42", menuName: 1, x: 0, y: 0 }), /optional menu name/);
  host.cancel();
  await assert.rejects(invoke({ windowId: "42", x: 0, y: 0 }));
  assert.equal(calls.length, 3);
  const defaults = runtime.host(2);
  assert.equal(runtime.slots.getMenuBarSlotBuilder(defaults.win).name, "menuBarBuilder");
});

test("native paste semantics preserve application dispatch and originating window", () => {
  const nativeCalls = [];
  const applicationCalls = [];
  const { MenuManager } = loader({
    "@ohos.web.webview": {},
    "@ohos-rs/ability": { ...base, MAIN_WINDOW_ID: 0 },
    "./MenuBarComponent": {},
  }).load("plugins/menu/src/main/ets/menu.ets");
  const manager = new MenuManager(
    { execute: (...args) => nativeCalls.push(args) },
    (...args) => applicationCalls.push(args),
  );
  manager.handleItemClick({ id: "editor-paste", type: "item", predefinedType: "paste" }, "42");
  assert.deepEqual(applicationCalls, [["editor-paste", "42"]]);
  assert.deepEqual(nativeCalls, []);
  manager.handleItemClick({ id: "web-paste", type: "predefined", predefinedType: "paste" }, "43");
  assert.deepEqual(nativeCalls, [["paste", undefined, 43]]);
  assert.equal(applicationCalls.length, 1);
});


test("native move decisions run inside the touch callback and target its window", async () => {
  const phases = { Down: 0, Up: 1, Move: 2, Cancel: 3 };
  const { WindowPlugin } = loader({}, { TouchType: phases }).load("plugins/window/src/main/ets/WindowPlugin.ets");
  const plugin = new WindowPlugin();
  const calls = [];
  let requested = true;
  let active = true;
  const target = { startMoving() { calls.push("move"); return Promise.resolve(); } };
  const context = {
    isActive: () => active,
    invokeNativeSync(name, requestType, responseType, request) {
      assert.equal(name, "move-requested");
      assert.equal(requestType, "ohos.window.MoveRequested");
      assert.equal(responseType, "ohos.window.MoveResponse");
      assert.equal(request.windowId, 23);
      calls.push("decision");
      return { startMoving: requested };
    },
  };
  const event = (type) => ({ windowId: 23, window: target, touch: { type } });
  plugin.onComponentTouch(event(phases.Down), context);
  assert.deepEqual(calls, ["decision", "move"]);
  requested = false;
  plugin.onComponentTouch(event(phases.Move), context);
  plugin.onComponentTouch(event(phases.Up), context);
  plugin.onComponentTouch(event(phases.Cancel), context);
  active = false;
  plugin.onComponentTouch(event(phases.Down), context);
  assert.deepEqual(calls, ["decision", "move", "decision"]);
  await flush();
});

test("component touch hooks are session isolated and stop before teardown", async () => {
  const { BridgeHostRegistry } = loader({
    "@ohos.app.ability.common": {}, "@ohos.arkui.node": {}, "@ohos.arkui.UIContext": {},
    "@ohos.resourceManager": {}, "../window/WindowManager": {},
  }).load("native_ability/src/main/ets/bridge/BridgeHost.ets");
  const calls = [];
  const session = async (label) => {
    const plugin = {
      id: "test.touch", execution: "async", requires: ["ability"],
      invokeAsync: async () => ({ typeName: "std.bool", value: true }),
      onComponentTouch(event, context) { calls.push([label, event.windowId, context.isActive()]); },
    };
    const id = BridgeHostRegistry.prepare([label], {}, [{ create: () => plugin }]);
    BridgeHostRegistry.configurePlugins(id, label, [{ id: plugin.id, execution: plugin.execution, requires: plugin.requires }]);
    BridgeHostRegistry.dispatchComponentTouch(id, label, { windowId: 99 });
    await BridgeHostRegistry.activateAbility(id, label, { kind: "ability-create", payload: {} });
    return id;
  };
  const first = await session("first");
  const second = await session("second");
  assert.deepEqual(calls, []);
  BridgeHostRegistry.dispatchComponentTouch(first, "first", { windowId: 1 });
  BridgeHostRegistry.dispatchComponentTouch(second, "second", { windowId: 2 });
  BridgeHostRegistry.beginClosing(first);
  BridgeHostRegistry.dispatchComponentTouch(first, "first", { windowId: 3 });
  await BridgeHostRegistry.dispose(first);
  BridgeHostRegistry.dispatchComponentTouch(first, "first", { windowId: 4 });
  assert.deepEqual(calls, [["first", 1, true], ["second", 2, true]]);
  await BridgeHostRegistry.dispose(second);
});


test("typed command popups preserve window routing and reject invalid or stale requests", async () => {
  const calls = [], runtime = menuRuntime();
  const host = runtime.host(1, { showMenuBar: false });
  runtime.windows.set(42, { getWindowProperties: () => ({ id: 42 }), getUIContext: () => ({ getHostContext: () => ({}) }) });
  runtime.registry.registerMenuDataCallback("native:42", {
    onMenuCommands: (...args) => calls.push(["42", ...args]),
  });
  const plugin = host.plugin;
  const request = { windowId: "42", items: [
    { id: "window-42:gpui-window-close", text: "Close", enabled: true },
    { id: "disabled", text: "Disabled", enabled: false },
  ], x: 16, y: 30 };
  const invoke = (value, context = host.context, typeName = "ohos.menu.PopupCommandsRequest") =>
    plugin.invokeAsync("popup-commands", { typeName, value }, context);
  const response = await invoke(request);
  assert.equal(response.typeName, "ohos.menu.Acknowledgement");
  assert.equal(response.value.accepted, true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "42");
  assert.deepEqual(Array.from(calls[0][1], item => ({ ...item })), request.items.map(item => ({ ...item, type: "item" })));
  assert.deepEqual(calls[0].slice(2), [16, 30, undefined]);
  await invoke({ ...request, restoreFocusId: "editor-42" });
  assert.deepEqual(calls[1].slice(2), [16, 30, "editor-42"]);
  for (const patch of [
    { windowId: "" }, { x: NaN }, { y: -1 }, { x: "16" }, { items: [] },
    { items: [request.items[0], request.items[0]] }, { items: [{ id: "x", text: " ", enabled: true }] },
    { items: [{ id: "x", text: "Close", enabled: 1 }] }, { items: [null] },
    { restoreFocusId: " " }, { restoreFocusId: 42 },
  ]) await assert.rejects(invoke({ ...request, ...patch }), /Invalid command menu/);
  await assert.rejects(invoke(null), /Invalid command menu/);
  await assert.rejects(invoke(request, { isActive: () => false }));
  await assert.rejects(invoke(request, { isActive: () => true }, "std.string"));
  runtime.registry.unregisterMenuDataCallback("native:42");
  const pending = assert.rejects(invoke(request), /cancelled/);
  host.cancel();
  await pending;
  assert.equal(calls.length, 2);
});


function floatingCloseRuntime({ intercepted = false, closable = true, destroyError } = {}) {
  const filename = path.join(root, "native_ability/src/main/ets/components/FloatPage.ets");
  const ast = ts.createSourceFile(filename, fs.readFileSync(filename, "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS);
  const component = ast.statements.find(statement => statement.name?.text === "FloatPage");
  const method = component.members.find(member => member.name?.text === "closeWindow");
  const printed = ts.createPrinter().printNode(ts.EmitHint.Unspecified, method, ast);
  const { outputText } = ts.transpileModule(`class FloatingClose { ${printed} }; exports.FloatingClose = FloatingClose;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  });
  const calls = [], exports = {};
  const context = vm.createContext({
    exports, DOMAIN: 0, NATIVE_MODULE_STORAGE_KEY: "native", hilog: quietConsole,
    WindowManager: { getInstance: () => ({
      getDecorationFlag(id, flag) { calls.push(["flag", id, flag]); return closable; },
      requestWindowClose(id) { calls.push(["request", id]); return intercepted; },
      removeWindow(id) { calls.push(["remove", id]); },
    }) },
    AppStorage: { get: () => ({
      notifyNativeWindowClose(id) { calls.push(["native-close", id]); },
      notifyWindowClose(id) { calls.push(["close", id]); },
    }) },
  });
  vm.runInContext(outputText, context, { filename });
  const page = new exports.FloatingClose();
  Object.assign(page, {
    windowId: 42, nativeModuleName: "zed", closeNotified: false,
    windowClass: { async destroyWindow() { calls.push(["destroy", 42]); if (destroyError) throw destroyError; } },
  });
  return { page, calls };
}

test("floating close keeps a window alive while its application handles confirmation", async () => {
  const { page, calls } = floatingCloseRuntime({ intercepted: true });
  await page.closeWindow();
  assert.equal(page.closeNotified, false);
  assert.deepEqual(calls, [["flag", 42, "closable"], ["request", 42]]);
});

test("floating close retains native cleanup when the application has no interceptor", async () => {
  const { page, calls } = floatingCloseRuntime();
  await page.closeWindow();
  assert.equal(page.closeNotified, true);
  assert.deepEqual(calls, [["flag", 42, "closable"], ["request", 42], ["native-close", 42], ["close", 42], ["remove", 42], ["destroy", 42]]);
  await page.closeWindow();
  assert.equal(calls.length, 6);
});

test("nonclosable floating windows cannot dispatch close or destroy", async () => {
  const { page, calls } = floatingCloseRuntime({ closable: false });
  await page.closeWindow();
  assert.equal(page.closeNotified, false);
  assert.deepEqual(calls, [["flag", 42, "closable"]]);
});


function menubarHoverRuntime() {
  const filename = path.join(root, "plugins/menu/src/main/ets/MenuBarComponent.ets");
  const ast = ts.createSourceFile(filename, fs.readFileSync(filename, "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS);
  const component = ast.statements.find(statement => statement.name?.text === "MenuBarComponent");
  const names = ["getMenubarItem", "switchMenubarOnHover", "observeDropdownMouse", "releaseDropdownMouse", "dropdownNodeId", "handleDropdownMouse"];
  const printer = ts.createPrinter();
  const methods = names.map(name => {
    const method = component.members.find(member => member.name?.text === name);
    assert.ok(method, `missing production menu method ${name}`);
    return printer.printNode(ts.EmitHint.Unspecified, method, ast);
  }).join("\n");
  let click;
  function visit(node) {
    if (ts.isArrowFunction(node) && node.parameters[0]?.type?.getText(ast) === "ClickEvent" &&
        node.getText(ast).includes("const pressedDuringDismissal")) {
      click = node.getText(ast);
    } else {
      ts.forEachChild(node, visit);
    }
  }
  visit(component);
  assert.ok(click, "missing production heading click handler");
  const { outputText } = ts.transpileModule(`class MenuLogic { ${methods}; headingClick(itemId: string, event: ClickEvent) { return (${click})(event); } }; exports.MenuLogic = MenuLogic;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  });
  const calls = [], exports = {}, nodes = new Map();
  vm.runInContext(outputText, vm.createContext({
    exports, hilog: quietConsole, MouseAction: { Move: 1, Press: 2 },
    SourceType: { Mouse: 1, TouchScreen: 2 },
    notifyMenuWillOpen: windowId => calls.push(["validate", windowId]),
  }), { filename });
  const menu = new exports.MenuLogic();
  Object.assign(menu, {
    windowId: 42, registryKey: () => "native:42", activeDropdownShown: false, activeDropdownId: "",
    headingPressId: "", headingPressAt: 0, dismissedDropdownAt: 0, dismissedDropdownId: "",
    menubarItems: [{ id: "file" }, { id: "edit" }, { id: "disabled", enabled: false }],
    menubarItemAreas: new Map(), dropdownMouseNodes: new Map(),
    getUIContext: () => ({ getFrameNodeById: id => nodes.get(id) }),
  });
  return { menu, calls, nodes };
}

test("hover switches only open enabled menu headings and retains their validation snapshot", () => {
  const { menu, calls } = menubarHoverRuntime();
  menu.switchMenubarOnHover("edit");
  assert.equal(menu.activeDropdownId, "");
  menu.activeDropdownShown = true;
  menu.activeDropdownId = "file";
  menu.switchMenubarOnHover("disabled");
  menu.switchMenubarOnHover("missing");
  assert.equal(menu.activeDropdownId, "file");
  menu.switchMenubarOnHover("edit");
  assert.equal(menu.activeDropdownId, "edit");
  assert.deepEqual(calls, []);
});

test("heading click closes an open menu and reopens a fully dismissed same heading", () => {
  const { menu, calls } = menubarHoverRuntime();
  menu.activeDropdownShown = true;
  menu.activeDropdownId = "file";
  menu.headingClick("file", { source: 1 });
  assert.equal(menu.activeDropdownShown, false);
  assert.equal(menu.activeDropdownId, "");
  menu.activeDropdownId = "file";
  menu.headingClick("file", { source: 1 });
  assert.equal(menu.activeDropdownShown, true);
  assert.equal(menu.activeDropdownId, "file");
  assert.deepEqual(calls, [["validate", 42]]);
});

test("the press dismissing a heading cannot immediately reopen it", () => {
  const { menu, calls } = menubarHoverRuntime();
  Object.assign(menu, { headingPressId: "file", headingPressAt: 100, dismissedDropdownId: "file", dismissedDropdownAt: 110 });
  menu.headingClick("file", { source: 1 });
  assert.equal(menu.activeDropdownShown, false);
  assert.deepEqual(calls, []);
});

test("dropdown wrapper mouse movement reaches heading hit tests and ignores presses", () => {
  const { menu } = menubarHoverRuntime();
  menu.activeDropdownShown = true;
  menu.activeDropdownId = "file";
  menu.menubarItemAreas.set("edit", { globalPosition: { x: 50, y: 5 }, width: 40, height: 30 });
  menu.handleDropdownMouse({ action: 2, windowX: 60, windowY: 10 });
  assert.equal(menu.activeDropdownId, "file");
  menu.handleDropdownMouse({ action: 1, windowX: 49, windowY: 10 });
  assert.equal(menu.activeDropdownId, "file");
  menu.handleDropdownMouse({ action: 1, windowX: 60, windowY: 10 });
  assert.equal(menu.activeDropdownId, "edit");
});

test("dropdown observers bind only their active wrapper and release idempotently", () => {
  const { menu, nodes } = menubarHoverRuntime();
  const listeners = [];
  const wrapper = { getNodeType: () => "MenuWrapper", commonEvent: { setOnMouse: listener => listeners.push(listener) } };
  nodes.set(menu.dropdownNodeId("file"), { getNodeType: () => "Menu", getParent: () => wrapper });
  menu.observeDropdownMouse("file");
  assert.equal(listeners.length, 0);
  menu.activeDropdownShown = true;
  menu.activeDropdownId = "file";
  menu.observeDropdownMouse("file");
  menu.observeDropdownMouse("file");
  assert.equal(listeners.length, 1);
  assert.equal(typeof listeners[0], "function");
  menu.releaseDropdownMouse("file");
  menu.releaseDropdownMouse("file");
  assert.equal(listeners.length, 2);
  assert.equal(listeners[1], undefined);
  assert.equal(menu.dropdownMouseNodes.size, 0);
});

function popupFocusRuntime({ requestError } = {}) {
  const filename = path.join(root, "plugins/menu/src/main/ets/MenuBarComponent.ets");
  const ast = ts.createSourceFile(filename, fs.readFileSync(filename, "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS);
  const component = ast.statements.find(statement => statement.name?.text === "MenuBarComponent");
  const method = component.members.find(member => member.name?.text === "restorePopupFocus");
  assert.ok(method, "missing production popup focus restoration");
  const callbacks = new Map();
  function visit(node) {
    if (ts.isPropertyAssignment(node) && ts.isArrowFunction(node.initializer) &&
        node.initializer.getText(ast).includes("this.restorePopupFocus(")) {
      callbacks.set(node.name.getText(ast), node.initializer.getText(ast));
    }
    ts.forEachChild(node, visit);
  }
  visit(component);
  assert.ok(callbacks.has("aboutToDisappear"));
  assert.ok(callbacks.has("onDisappear"));
  const printed = ts.createPrinter().printNode(ts.EmitHint.Unspecified, method, ast);
  const { outputText } = ts.transpileModule(`class PopupFocus {
    ${printed}
    beginDismissal() { return (${callbacks.get("aboutToDisappear")})(); }
    finishDismissal() { return (${callbacks.get("onDisappear")})(); }
  }; exports.PopupFocus = PopupFocus;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  });
  const exports = {}, calls = [], warnings = [];
  vm.runInContext(outputText, vm.createContext({ exports,
    hilog: { warn: (...args) => warnings.push(args) },
  }), { filename });
  const menu = new exports.PopupFocus();
  Object.assign(menu, {
    menuShown: true, restoreFocusId: "editor-42",
    getUIContext: () => ({ getFocusController: () => ({ requestFocus(identifier) {
      calls.push(identifier);
      if (requestError) throw requestError;
    } }) }),
  });
  return { menu, calls, warnings };
}

test("native popup dismissal restores content focus synchronously before window activation", () => {
  const { menu, calls } = popupFocusRuntime();
  menu.beginDismissal();
  assert.equal(menu.menuShown, false);
  assert.deepEqual(calls, ["editor-42"]);
  assert.equal(menu.restoreFocusId, "editor-42");
  menu.finishDismissal();
  assert.deepEqual(calls, ["editor-42", "editor-42"]);
  assert.equal(menu.restoreFocusId, undefined);
  menu.finishDismissal();
  assert.equal(calls.length, 2);
});

test("child dismissal and an older popup callback cannot steal a replacement popup's focus", () => {
  const { menu, calls } = popupFocusRuntime();
  menu.finishDismissal();
  assert.deepEqual(calls, []);
  assert.equal(menu.restoreFocusId, "editor-42");
  menu.beginDismissal();
  menu.menuShown = true;
  menu.restoreFocusId = "other-editor";
  menu.finishDismissal();
  assert.deepEqual(calls, ["editor-42"]);
  assert.equal(menu.restoreFocusId, "other-editor");
});

test("popup dismissal preserves unspecified focus and releases a destroyed target after logging", () => {
  const unchanged = popupFocusRuntime();
  unchanged.menu.restoreFocusId = undefined;
  unchanged.menu.beginDismissal();
  unchanged.menu.finishDismissal();
  assert.deepEqual(unchanged.calls, []);
  const removed = popupFocusRuntime({ requestError: new Error("target removed") });
  removed.menu.beginDismissal();
  removed.menu.finishDismissal();
  assert.equal(removed.menu.restoreFocusId, undefined);
  assert.equal(removed.warnings.length, 2);
});


test("close registrations from modules sharing a session survive each other's lifecycle", async () => {
  const { manager, l } = managerFor();
  const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
  const first = new WindowPlugin(), second = new WindowPlugin(), calls = [];
  const context = (name, veto) => ({ sessionId: "shared", isActive: () => true,
    invokeNativeSync() { calls.push(name); return { preventClose: veto }; } });
  const firstContext = context("first", true), secondContext = context("second", false);
  first.onLifecycle({ kind: "window-stage-create" }, firstContext);
  second.onLifecycle({ kind: "window-stage-create" }, secondContext);
  assert.equal(manager.requestWindowClose(0), true);
  assert.deepEqual(calls, ["first"]);
  calls.length = 0;
  second.onLifecycle({ kind: "window-stage-destroy" }, secondContext);
  assert.equal(manager.requestWindowClose(0), true);
  assert.deepEqual(calls, ["first"]);
  await first.onDispose();
  assert.equal(manager.requestWindowClose(0), false);
});

test("window zero targets its component host before the process primary", async () => {
  const { manager, l } = managerFor();
  const { WindowPlugin } = l.load("plugins/window/src/main/ets/WindowPlugin.ets");
  const primary = {}, secondary = {};
  manager.uiAbilityStages.set(0, { getMainWindowSync: () => primary });
  const plugin = new WindowPlugin();
  assert.equal(await plugin.requireWindow(0, { isActive: () => true, getWindow: () => secondary }), secondary);
  assert.equal(await plugin.requireWindow(0, { isActive: () => true, getWindow: () => undefined }), primary);
});

test("clipboard observation retries after a transient connection failure", async () => {
  let attempts = 0, writes = 0, listener;
  const board = { hasData() { return ++attempts === 1 ? Promise.reject(new Error("starting")) : Promise.resolve(false); },
    on(_event, callback) { listener = callback; }, off() {}, async setData() { writes++; } };
  const { ClipboardPlugin } = loader({ "@kit.ArkTS": {}, "@ohos.pasteboard": {
    getSystemPasteboard: () => board, createData: (_mime, text) => ({ text }),
    MIMETYPE_TEXT_PLAIN: "text/plain" } }).load("plugins/clipboard/src/main/ets/ClipboardPlugin.ets");
  const plugin = new ClipboardPlugin({ metadataMimeType: "application/x-test" });
  let changed = 0;
  const context = { isActive: () => true, invokeNativeSync() { changed++; } };
  const request = { typeName: "ohos.clipboard.WriteTextRequest", value: { text: "retry" } };
  plugin.onInstall(context);
  await assert.rejects(plugin.invokeAsync("write-text", request, context), /starting/);
  await plugin.invokeAsync("write-text", request, context);
  listener();
  assert.equal(attempts, 2);
  assert.equal(writes, 1);
  assert.equal(changed, 1);
  plugin.onDispose();
});


test("an independent window notifies the native module which created it", async () => {
  const state = abilityWindowRuntime();
  const options = { ...state.options(7), nativeModuleName: "secondary-module" };
  const creation = state.manager.createSubWindow(options);
  const instance = state.attach(7);
  await creation;
  await state.manager.destroyWindow(7);
  instance.ability.onDestroy();
  assert.deepEqual(state.notifiedModules, ["secondary-module"]);
});

test("a fullscreen Ability window does not require floating geometry", async () => {
  const state = abilityWindowRuntime();
  const creation = state.manager.createSubWindow(state.options(7));
  const instance = state.attach(7);
  instance.win.getWindowStatus = () => windowApi.WindowStatusType.FULL_SCREEN;
  instance.win.resize = async () => { assert.fail("fullscreen cannot resize"); };
  instance.win.moveWindowTo = async () => { assert.fail("fullscreen cannot move"); };
  await creation;
  assert.equal(state.manager.getWindow(7), instance.win);
  await state.manager.destroyWindow(7);
});

// Multi-host regressions: logical main/zero is local to each component.
test("menu configuration, content, events and disposal remain window-owned", async () => {
  const runtime = menuRuntime(), calls = [];
  const a = runtime.host(11, { showMenuBar: false, handleKeyboardShortcuts: false });
  const b = runtime.host(22);
  for (const host of [a, b]) {
    runtime.registry.registerMenuDataCallback(host.key, {
      onMenubarJson: json => calls.push([host.key, json]),
      onMenubarVisible: visible => calls.push([host.key, visible]),
    });
    runtime.matchers.getAcceleratorMatcher(host.key).matches = () => true;
    runtime.matchers.getAcceleratorMatcher(host.key).getMatchedItem = () => ({ id: "shared-id", type: "item" });
    await host.invoke("set-menubar", { windowId: "main", jsonData: host.key }, "SetMenubarRequest");
    runtime.registry.notifyMenuWillOpen(0, host.key);
  }
  assert.deepEqual(calls, [[a.key, a.key], [b.key, b.key]]);
  assert.equal(runtime.slots.getMenuBarSlotBuilder(a.win).name, "menuPopupBuilder");
  assert.equal(runtime.slots.getMenuBarSlotBuilder(b.win).name, "menuBarBuilder");
  const event = { type: 0, keyCode: 2019 };
  assert.equal(runtime.slots.getMenuBarPort(a.win).onKeyPreIme(event, 0), false);
  assert.equal(runtime.slots.getMenuBarPort(b.win).onKeyPreIme(event, 0), true);
  runtime.slots.getMenuBarPort(a.win).onMenubarVisibility(0, false);
  assert.deepEqual(calls.at(-1), [a.key, false]);
  assert.deepEqual(runtime.events.map(([id, name]) => [id, name]), [[11, "menu-open"], [22, "menu-open"], [22, "menu-click"]]);
  a.plugin.onDispose();
  a.plugin.onDispose();
  assert.equal(runtime.slots.getMenuBarPort(a.win), null);
  assert.equal(runtime.registry.getMenuClickHandler(a.key), null);
  assert.equal(runtime.slots.getMenuBarPort(b.win).onKeyPreIme(event, 0), true);
  assert.equal(runtime.events.at(-1)[0], 22);
  // Replacing a window's explicit registration cannot be undone by an older owner.
  const newer = runtime.host(22, { showMenuBar: false });
  b.plugin.onDispose();
  assert.equal(runtime.slots.getMenuBarSlotBuilder(newer.win).name, "menuPopupBuilder");
  assert.notEqual(runtime.registry.getMenuClickHandler(newer.key), null);
});

test("menu attachment follows actual mount and cancellation, including child-window teardown", async () => {
  const runtime = menuRuntime(), calls = [];
  const host = runtime.host(1);
  const child = { getWindowProperties: () => ({ id: 42 }), getUIContext: () => ({ getHostContext: () => ({}) }) };
  runtime.windows.set(42, child);
  const pending = host.invoke("popup-commands", {
    windowId: "42", items: [{ id: "close", text: "Close", enabled: true }], x: 1, y: 2,
  }, "PopupCommandsRequest");
  await flush();
  assert.notEqual(runtime.slots.getMenuBarSlotBuilder(child), null);
  runtime.registry.registerMenuDataCallback("native:42", { onMenuCommands: items => calls.push(items[0].id) });
  await pending;
  assert.deepEqual(calls, ["close"]);
  runtime.registry.unregisterMenuDataCallback("native:42");
  const cancelled = assert.rejects(host.invoke("set-menubar", { windowId: "42", jsonData: "[]" }, "SetMenubarRequest"), /cancelled/);
  runtime.slots.getMenuBarPort(child).onHostDisappear();
  await cancelled;
  assert.equal(runtime.slots.getMenuBarPort(child), null);
  assert.notEqual(runtime.slots.getMenuBarPort(host.win), null);
});

test("old menu APIs build popup options without referring to ModalMode", () => {
  const filename = path.join(root, "plugins/menu/src/main/ets/MenuBarComponent.ets");
  const ast = ts.createSourceFile(filename, fs.readFileSync(filename, "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS);
  const component = ast.statements.find(s => s.name?.text === "MenuBarComponent");
  const method = component.members.find(member => member.name?.text === "popupOptions");
  const { outputText } = ts.transpileModule(`class MenuProbe { ${method.getText(ast)} }; globalThis.MenuProbe = MenuProbe;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2022 },
  });
  for (const api of [12, 14, 19, 20]) {
    const sandbox = { deviceInfo: { sdkApiVersion: api }, TransitionEffect: { IDENTITY: { animation: () => ({}) } } };
    if (api >= 20) sandbox.ModalMode = { AUTO: 0, TARGET_WINDOW: 1 };
    vm.runInNewContext(outputText, sandbox);
    for (const applicationMenu of [false, true]) {
      const probe = new sandbox.MenuProbe();
      Object.assign(probe, { menuX: 1, menuY: 2, applicationMenu, commandMenu: false });
      const options = probe.popupOptions();
      assert.equal(options.modalMode, api < 20 ? undefined : Number(applicationMenu));
      assert.equal(typeof options.aboutToDisappear, "function");
      assert.equal(typeof options.onDisappear, "function");
    }
  }
});

test("two component-local zero aliases restore their own fullscreen bounds and queues", async () => {
  const { manager } = managerFor(), restoredA = [], restoredB = [];
  function nativeWindow(bounds, events) {
    return {
      getWindowProperties: () => ({ windowRect: bounds }),
      getWindowStatus: () => windowApi.WindowStatusType.FLOATING,
      async maximize() {}, async recover() {}, async setTitleAndDockHoverShown() {},
      async resize(width, height) { events.push(["resize", width, height]); },
      async moveWindowTo(x, y) { events.push(["move", x, y]); },
    };
  }
  const a = nativeWindow({ left: 10, top: 20, width: 700, height: 500 }, restoredA);
  const b = nativeWindow({ left: 200, top: 300, width: 950, height: 800 }, restoredB);
  await manager.setFullscreenAsync(0, true, { window: a });
  await manager.setFullscreenAsync(0, true, { window: b });
  const gate = deferred();
  const blocked = manager.serializeOp(0, () => gate.promise, a);
  // B must not wait for A even though both callers use zero.
  await manager.setFullscreenAsync(0, false, { window: b });
  assert.deepEqual(restoredB, [["resize", 950, 800], ["move", 200, 300]]);
  gate.resolve();
  await blocked;
  // A different logical alias of A still reaches A's original snapshot.
  await manager.setFullscreenAsync(99, false, { window: a });
  assert.deepEqual(restoredA, [["resize", 700, 500], ["move", 10, 20]]);
});

test("file picker zero resolves the requesting component's actual window", async () => {
  const primary = {}, componentContext = { name: "secondary" };
  const componentWindow = { getUIContext: () => ({ getHostContext: () => componentContext }) };
  const files = filesFor({ windows: new Map([[0, primary]]) });
  files.context.getWindow = () => componentWindow;
  await files.invoke({ parentWindowId: 0 });
  assert.equal(files.constructions[0].parent, componentWindow);
  assert.equal(files.constructions[0].context, componentContext);
  files.context.getWindow = () => { throw new Error("component detached"); };
  await assert.rejects(files.invoke({ parentWindowId: 0 }), /component detached/);
  assert.equal(files.constructions.length, 1);
});

test("hidden independent windows accept configuration before show and reject premature native queries", async () => {
  const state = abilityWindowRuntime();
  const creation = state.manager.createSubWindow({ ...state.options(7), show: false });
  const { WindowPlugin } = state.runtime.load("plugins/window/src/main/ets/WindowPlugin.ets");
  const plugin = new WindowPlugin();
  const invoke = (action, type, value, active = true) => plugin.invokeAsync(action, {
    typeName: `ohos.window.${type}`, value: { windowId: 7, ...value },
  }, { isActive: () => active });
  await invoke("resize", "ResizeRequest", { width: 960, height: 720 });
  await invoke("move-to", "MoveRequest", { x: 30, y: 40 });
  await invoke("set-background-color", "ColorRequest", { color: 0xff123456 });
  await assert.rejects(invoke("resize", "ResizeRequest", { width: -1, height: 400 }));
  await assert.rejects(invoke("resize", "ResizeRequest", { width: 1, height: 1 }, false), /no longer active/);
  await assert.rejects(invoke("is-maximized", "WindowIdRequest", {}), /not ready/);
  assert.equal(state.started.length, 0);
  const showing = invoke("show", "WindowIdRequest", {});
  await flush();
  assert.equal(state.started.length, 1);
  const options = state.started[0].options;
  assert.deepEqual([options.windowLeft, options.windowTop, options.windowWidth, options.windowHeight], [30, 40, 960, 720]);
  const instance = state.attach(7);
  await Promise.all([creation, showing]);
  assert.deepEqual(instance.geometry, [["background", "#ff123456"]]);
});

test("WebView keyboard policy distinguishes native windows from another host's logical zero", () => {
  const flags = loader().load("native_ability/src/main/ets/helper/window_flags.ets");
  const a = {}, b = {};
  flags.setClipboardEnabled(0, false, a);
  flags.setZoomHotkeysEnabled(0, false, a);
  assert.equal(flags.hasWebviewKeyboardPolicy(0, b), false);
  assert.equal(flags.isClipboardEnabled(0, b), true);
  flags.setClipboardEnabled(0, true, b);
  flags.clearClipboardEnabled(0, a);
  flags.clearZoomHotkeysEnabled(0, a);
  assert.equal(flags.hasWebviewKeyboardPolicy(0, a), false);
  assert.equal(flags.hasWebviewKeyboardPolicy(0, b), true);
});

test("predefined window actions target their own component even when another host installs last", async () => {
  const runtime = menuRuntime(), calls = [];
  const a = runtime.host(11), b = runtime.host(22);
  a.win.minimize = async () => calls.push("a");
  b.win.minimize = async () => calls.push("b");
  await a.invoke("execute-predefined", { action: "minimize", windowId: "main" }, "PredefinedRequest");
  await b.invoke("execute-predefined", { action: "minimize", windowId: "main" }, "PredefinedRequest");
  assert.deepEqual(calls, ["a", "b"]);
});

test("a pending menu request cannot write through a later owner's window registration", async () => {
  const runtime = menuRuntime();
  const a = runtime.host(11);
  const rejected = assert.rejects(a.invoke("set-menubar", {
    windowId: "main", jsonData: "stale",
  }, "SetMenubarRequest"), /ownership changed/);
  await flush();
  const b = runtime.host(11);
  const calls = [];
  runtime.registry.registerMenuDataCallback(b.key, { onMenubarJson: json => calls.push(json) });
  await rejected;
  assert.deepEqual(calls, []);
  await b.invoke("set-menubar", { windowId: "main", jsonData: "current" }, "SetMenubarRequest");
  assert.deepEqual(calls, ["current"]);
});

test("primary WebView controller attachment and stale unsubscribe remain window-scoped", () => {
  const filename = path.join(root, "native_ability/src/main/ets/components/DefaultXComponent.ets");
  const ast = ts.createSourceFile(filename, fs.readFileSync(filename, "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS);
  const functions = new Set(["setPrimaryWebviewControllerCallback", "clearPrimaryWebviewControllerCallback", "notifyPrimaryWebviewController"]);
  const variables = new Set(["primaryWebviewControllerCallback", "windowControllerCallbacks"]);
  const statements = ast.statements.filter(node => ts.isFunctionDeclaration(node) && functions.has(node.name?.text) ||
    ts.isVariableStatement(node) && node.declarationList.declarations.some(d => variables.has(d.name.getText(ast))));
  const { outputText } = ts.transpileModule(ts.createPrinter().printFile(ts.factory.updateSourceFile(ast, statements)), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  });
  const exports = {}, calls = [];
  vm.runInNewContext(outputText, { exports });
  const a = { getWindowProperties: () => ({ id: 11 }) }, b = { getWindowProperties: () => ({ id: 22 }) };
  const old = exports.setPrimaryWebviewControllerCallback(value => calls.push(["old", value]), a);
  exports.setPrimaryWebviewControllerCallback(value => calls.push(["a", value]), a);
  exports.setPrimaryWebviewControllerCallback(value => calls.push(["b", value]), b);
  old();
  exports.notifyPrimaryWebviewController("controller-b", b);
  exports.notifyPrimaryWebviewController("controller-a", a);
  exports.notifyPrimaryWebviewController("duplicate", a);
  assert.deepEqual(calls, [["b", "controller-b"], ["a", "controller-a"]]);
});

test("legacy menu ports route child IDs while explicit ports distinguish local zero aliases", async () => {
  const runtime = menuRuntime(), calls = [];
  const a = runtime.host(11), b = runtime.host(22);
  const child = { getWindowProperties: () => ({ id: 42 }), getUIContext: () => ({ getHostContext: () => ({}) }) };
  runtime.windows.set(42, child);
  for (const key of [a.key, b.key, "native:42"]) {
    runtime.registry.registerMenuDataCallback(key, {
      onMenubarJson() {},
      onMenubarVisible: visible => calls.push([key, visible]),
    });
  }
  await a.invoke("set-menubar", { windowId: "42", jsonData: "[]" }, "SetMenubarRequest");
  const legacy = runtime.slots.getMenuBarPort();
  legacy.onMenubarVisibility(42, false);
  legacy.onMenubarVisibility(0, false);
  runtime.slots.getMenuBarPort(b.win).onMenubarVisibility(0, true);
  assert.deepEqual(calls, [["native:42", false], [a.key, false], [b.key, true]]);
  assert.equal(runtime.slots.getMenuBarSlotBuilder(), runtime.slots.getMenuBarSlotBuilder(a.win));
  a.plugin.onDispose();
  legacy.onMenubarVisibility(42, true);
  assert.equal(calls.length, 3);
  legacy.onMenubarVisibility(0, false);
  assert.deepEqual(calls.at(-1), [b.key, false]);
});

test("direct menu components derive their host identity and stale teardown preserves a replacement", async () => {
  const runtime = menuRuntime();
  const filename = path.join(root, "plugins/menu/src/main/ets/MenuBarComponent.ets");
  const ast = ts.createSourceFile(filename, fs.readFileSync(filename, "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS);
  const component = ast.statements.find(node => node.name?.text === "MenuBarComponent");
  const methods = ["registryKey", "aboutToAppear", "aboutToDisappear"].map(name =>
    component.members.find(member => member.name?.text === name).getText(ast)).join("\n");
  const { outputText } = ts.transpileModule(`class MenuMount { ${methods} }; exports.MenuMount = MenuMount;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  });
  const exports = {};
  vm.runInNewContext(outputText, { exports, ...runtime.registry, ...runtime.matchers,
    menuKeyForWindow: runtime.slots.menuKeyForWindow,
    window: { findWindow: name => runtime.windows.get(Number(name)) },
  });
  function mount(id) {
    const menu = new exports.MenuMount();
    Object.assign(menu, {
      windowId: 0, menuKey: "", hostMenuKey: "", menubarVisible: true,
      dropdownMouseNodes: new Map(), menubarItemAreas: new Map(), iconPixelMaps: new Map(),
      popupIconIds: new Set(), menubarIconIds: new Set(),
      getUIContext: () => ({ getWindowName: () => String(id) }),
    });
    menu.aboutToAppear();
    return menu;
  }
  const a = runtime.host(11), b = runtime.host(22);
  const menuA = mount(11), menuB = mount(22);
  await a.invoke("set-menubar", { windowId: "main", jsonData: "a" }, "SetMenubarRequest");
  await b.invoke("set-menubar", { windowId: "main", jsonData: "b" }, "SetMenubarRequest");
  assert.equal(menuA.menubarJson, "a");
  assert.equal(menuB.menubarJson, "b");
  assert.equal(menuA.acceleratorMatcher, runtime.matchers.getAcceleratorMatcher(a.key));
  const replacement = mount(11);
  menuA.aboutToDisappear();
  menuA.aboutToDisappear();
  await a.invoke("set-menubar", { windowId: "main", jsonData: "replacement" }, "SetMenubarRequest");
  assert.equal(replacement.menubarJson, "replacement");
  assert.equal(menuB.menubarJson, "b");
  replacement.aboutToDisappear();
  assert.equal(runtime.registry.getMenuDataCallback(a.key), undefined);
});
