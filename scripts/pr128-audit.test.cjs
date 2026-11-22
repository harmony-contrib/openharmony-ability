// Unit tests for PR #128 audit fixes across DisplayGeometry, NowPlayingController,
// SystemStatePlugin, WebviewPendingHandlers, and WebviewAsyncEval.
// Run: ABILITY_TYPESCRIPT=/path/to/typescript node --test scripts/pr128-audit.test.cjs
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const ts = require(process.env.ABILITY_TYPESCRIPT || "typescript");

const bridge = {
  AsyncPluginBase: class {},
  BridgeAcknowledgement: class {
    constructor(accepted) {
      this.accepted = accepted;
    }
  },
  expectBridgeRequestType(payload, _plugin, _action, type) {
    assert.equal(payload.typeName, type);
    return payload.value;
  },
};

function load(relative, imports) {
  const filename = path.join(__dirname, "..", relative);
  const output = ts.transpileModule(fs.readFileSync(filename, "utf8"), {
    fileName: filename.replace(/\.ets$/, ".ts"),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    reportDiagnostics: true,
  });
  assert.equal(output.diagnostics.length, 0);
  const mod = { exports: {} };
  const requireDouble = (name) => {
    if (name === "@ohos-rs/ability") return bridge;
    assert.ok(Object.hasOwn(imports, name), `unexpected import ${name}`);
    return imports[name];
  };
  new Function("require", "module", "exports", output.outputText)(
    requireDouble,
    mod,
    mod.exports,
  );
  return mod.exports;
}

test("DisplayGeometry falls back to windowRect on API 12 without calling getGlobalRect", () => {
  const deviceInfo = { sdkApiVersion: 12 };
  const { WindowDisplayGeometry } = load("plugins/window/src/main/ets/DisplayGeometry.ets", {
    "@kit.BasicServicesKit": { deviceInfo },
    "@ohos.window": {},
    "@ohos.display": { default: { getDisplayByIdSync: () => ({ x: 0, y: 0 }) } },
    "@ohos.arkui.node": {},
  });
  let globalCalled = false;
  const win = {
    getWindowProperties: () => ({
      displayId: 2,
      windowRect: { left: 10, top: 20, width: 800, height: 600 },
      drawableRect: { left: 0, top: 37, width: 800, height: 563 },
    }),
    getGlobalRect() {
      globalCalled = true;
      return { left: 100, top: 200, width: 800, height: 600 };
    },
  };
  const g12 = new WindowDisplayGeometry(win, undefined);
  assert.equal(globalCalled, false);
  assert.equal(g12.bounds.left, 10);
  assert.equal(g12.bounds.top, 20);

  deviceInfo.sdkApiVersion = 13;
  const g13 = new WindowDisplayGeometry(win, undefined);
  assert.equal(globalCalled, true);
  assert.equal(g13.bounds.left, 100);
  assert.equal(g13.bounds.top, 200);
});

test("NowPlayingController dynamically toggles command listeners via bitmask and supports reset", async () => {
  const listeners = new Map();
  const metadataCalls = [];
  let destroyed = 0;
  const session = {
    on(name, cb) {
      listeners.set(name, cb);
    },
    off(name, cb) {
      if (listeners.get(name) === cb) listeners.delete(name);
    },
    async setAVMetadata(meta) {
      // Real OHOS AVSession NAPI parser rejects own properties with undefined values.
      if ("mediaImage" in meta && meta.mediaImage === undefined) {
        throw new Error("get metaData failed");
      }
      if ("duration" in meta && meta.duration === undefined) {
        throw new Error("get metaData failed");
      }
      metadataCalls.push(meta);
    },
    async setAVPlaybackState() {},
    async activate() {},
    async deactivate() {},
    async destroy() {
      destroyed++;
      listeners.clear();
    },
  };
  const mod = load("plugins/system-state/src/main/ets/NowPlayingController.ets", {
    "@ohos.multimedia.avsession": {
      default: {
        PlaybackState: { PLAYBACK_STATE_PLAY: 2, PLAYBACK_STATE_PAUSE: 3, PLAYBACK_STATE_STOP: 1 },
        async createAVSession() {
          return session;
        },
      },
    },
    "@kit.ImageKit": { image: {} },
    "@kit.AbilityKit": { common: {} },
  });
  const emitted = [];
  const hookCtx = {
    isActive: () => true,
    invokeNativeSync(_ev, _reqType, _resType, value) {
      emitted.push(value);
      return true;
    },
  };
  const ctrl = new mod.NowPlayingController();
  const baseReq = {
    active: true,
    title: "Song",
    artist: "Artist",
    album: "Album",
    state: "playing",
    durationMs: 60000,
    positionMs: 1000,
    rate: 1.0,
    commands: mod.MEDIA_CMD_PLAY | mod.MEDIA_CMD_SEEK,
  };
  assert.equal(await ctrl.apply(baseReq, {}, hookCtx), true);
  assert.deepEqual(Array.from(listeners.keys()).sort(), ["play", "seek"]);

  listeners.get("play")();
  listeners.get("seek")(1234.6);
  assert.deepEqual(
    emitted.map((e) => ({ command: e.command, positionMs: e.positionMs })),
    [
      { command: "play", positionMs: 0 },
      { command: "seek", positionMs: 1235 },
    ],
  );

  // Update mask: remove play, add pause and next
  await ctrl.apply(
    { ...baseReq, commands: mod.MEDIA_CMD_PAUSE | mod.MEDIA_CMD_NEXT },
    {},
    hookCtx,
  );
  assert.deepEqual(Array.from(listeners.keys()).sort(), ["pause", "playNext"]);

  // Dispose then reset allows reuse on reinstall
  await ctrl.dispose();
  assert.equal(destroyed, 1);
  assert.equal(await ctrl.apply(baseReq, {}, hookCtx), false);
  ctrl.reset();
  assert.equal(await ctrl.apply(baseReq, {}, hookCtx), true);
  assert.deepEqual(Array.from(listeners.keys()).sort(), ["play", "seek"]);
});

test("SystemStatePlugin suspend-delay cancels on timeout, emits event, and power-status uses isBatteryPresent", async () => {
  const cancelledIds = [];
  let timeoutCallback = null;
  const batteryInfo = {
    isBatteryPresent: false,
    batterySOC: 100,
    pluggedType: 0,
    BatteryPluggedType: { NONE: 0, AC: 1 },
  };
  const emitted = [];
  const { SystemStatePlugin } = load("plugins/system-state/src/main/ets/SystemStatePlugin.ets", {
    "@ohos.i18n": { default: { System: {} } },
    "@ohos.net.connection": {
      default: {
        createNetConnection: () => ({ on() {}, register() {}, unregister() {} }),
      },
    },
    "@ohos.commonEventManager": {
      default: {
        Support: {},
        createSubscriber: async () => ({}),
        subscribe() {},
        unsubscribe(_s, cb) {
          cb();
        },
      },
    },
    "@ohos.thermal": { default: { getLevel: () => 0 } },
    "@ohos.runningLock": { default: {} },
    "@ohos.display": {
      default: {
        getDefaultDisplaySync: () => ({ on() {}, off() {} }),
        on() {},
        off() {},
      },
    },
    "@kit.BasicServicesKit": { batteryInfo, deviceInfo: { sdkApiVersion: 26 } },
    "@kit.AbilityKit": { bundleManager: {} },
    "@kit.BackgroundTasksKit": {
      backgroundTaskManager: {
        requestSuspendDelay(_reason, cb) {
          timeoutCallback = cb;
          return { requestId: 42 };
        },
        cancelSuspendDelay(id) {
          cancelledIds.push(id);
        },
      },
    },
    "./ThermalSubscriptions": { ThermalSubscriptions: { subscribe: () => () => {} } },
    "./NowPlayingController": {
      NowPlayingController: class {
        reset() {}
        async dispose() {}
      },
    },
  });

  const plugin = new SystemStatePlugin();
  const hookCtx = {
    isActive: () => true,
    invokeNativeSync(_ev, _req, _res, value) {
      emitted.push(value);
      return true;
    },
  };
  plugin.onInstall(hookCtx);
  const callCtx = { isActive: () => true, abilityContext: {} };

  // Power status respects isBatteryPresent=false even when SOC=100
  const powerRes = await plugin.invokeAsync(
    "get-power-status",
    { typeName: "ohos.system-state.GetPowerStatusRequest", value: {} },
    callCtx,
  );
  assert.equal(powerRes.value.hasBattery, false);
  assert.equal(powerRes.value.onBattery, false);

  // Suspend delay request uses dedicated type and cancels itself on timeout
  const reqRes = await plugin.invokeAsync(
    "request-suspend-delay",
    { typeName: "ohos.system-state.SuspendDelayRequest", value: { reason: "save state" } },
    callCtx,
  );
  assert.equal(reqRes.typeName, "ohos.system-state.SuspendDelayResponse");
  assert.ok(reqRes.value.id.startsWith("suspend-"));

  timeoutCallback();
  assert.deepEqual(cancelledIds, [42]);
  assert.ok(emitted.some((e) => e.kind === "suspend-delay-expired"));

  // Cancelling after timeout is idempotent and does not double-cancel
  await plugin.invokeAsync(
    "cancel-suspend-delay",
    { typeName: "ohos.system-state.CancelSuspendDelayRequest", value: { id: reqRes.value.id } },
    callCtx,
  );
  assert.deepEqual(cancelledIds, [42]);
  await plugin.onDispose();
});

test("WebviewPendingHandlers cleans synthetic downloads and clears nav-scoped handlers on navigation", () => {
  const { WebviewPendingHandlers } = load(
    "plugins/webview/src/main/ets/WebviewPendingHandlers.ets",
    { "@ohos.web.webview": { default: {} } },
  );
  const pending = new WebviewPendingHandlers();
  let dlCancelled = 0;
  let permDenied = 0;
  let authCancelled = 0;
  let sslCancelled = 0;

  const dlItem = {
    getGuid: () => "",
    start() {},
    cancel() {
      dlCancelled++;
    },
  };
  pending.trackDownload("dl-1", dlItem);
  pending.trackPermission("p-1", {
    deny() {
      permDenied++;
    },
  });
  pending.trackHttpAuth("a-1", {
    cancel() {
      authCancelled++;
    },
  });
  pending.trackSslError("s-1", {
    handleCancel() {
      sslCancelled++;
    },
  });

  // Navigation clears permission/auth/ssl but preserves active downloads
  pending.clearNavigationPending();
  assert.equal(permDenied, 1);
  assert.equal(authCancelled, 1);
  assert.equal(sslCancelled, 1);
  assert.equal(dlCancelled, 0);

  // untrackDownload cleans up synthetic-GUID download via WeakMap
  pending.untrackDownload(dlItem);
  assert.equal(
    pending.resolveDownload({ id: "w", downloadId: "dl-1", allow: false, path: null }),
    false,
  );
});

test("WebviewAsyncEvaluator resolves via JS proxy without polling and handles undefined vs empty string", async () => {
  const { WebviewAsyncEvaluator, ASYNC_EVAL_PROXY_NAME } = load(
    "plugins/webview/src/main/ets/WebviewAsyncEval.ets",
    { "@ohos.web.webview": { default: {} } },
  );
  const evaluator = new WebviewAsyncEvaluator();
  const sandbox = { globalThis: {} };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);

  let registered = false;
  let deleted = false;
  const controller = {
    registerJavaScriptProxy(proxy, name, methods) {
      assert.equal(name, ASYNC_EVAL_PROXY_NAME);
      assert.deepEqual(methods, ["complete"]);
      sandbox[name] = proxy;
      registered = true;
    },
    deleteJavaScriptRegister(name) {
      assert.equal(name, ASYNC_EVAL_PROXY_NAME);
      delete sandbox[name];
      deleted = true;
    },
    async runJavaScript(code) {
      const result = vm.runInContext(code, sandbox);
      return JSON.stringify(result);
    },
  };

  evaluator.attach(controller);
  assert.equal(registered, true);

  const noCancel = () => () => {};
  const rVal = await evaluator.evaluate(controller, "return 40 + 2;", () => true, noCancel, 2000);
  assert.equal(rVal.ok, true);
  assert.equal(rVal.value, "42");

  const rEmpty = await evaluator.evaluate(controller, 'return "";', () => true, noCancel, 2000);
  assert.equal(rEmpty.ok, true);
  assert.equal(rEmpty.value, "");

  const rUndef = await evaluator.evaluate(controller, "const x = 1;", () => true, noCancel, 2000);
  assert.equal(rUndef.ok, true);
  assert.equal(rUndef.value, undefined);

  const rErr = await evaluator.evaluate(
    controller,
    'throw new Error("boom");',
    () => true,
    noCancel,
    2000,
  );
  assert.equal(rErr.ok, false);
  assert.match(rErr.error, /boom/);

  const rSyntax = await evaluator.evaluate(controller, "return (;", () => true, noCancel, 2000);
  assert.equal(rSyntax.ok, false);
  assert.equal(rSyntax.isSyntaxError, true);

  // Navigation cancels in-flight async script immediately
  const pendingPromise = evaluator.evaluate(
    controller,
    "await new Promise(() => {});",
    () => true,
    noCancel,
    5000,
  );
  evaluator.onNavigationStart();
  const rNav = await pendingPromise;
  assert.equal(rNav.ok, false);
  assert.match(rNav.error, /navigation/);

  evaluator.detach(controller);
  assert.equal(deleted, true);
});
