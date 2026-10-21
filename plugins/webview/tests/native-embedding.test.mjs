import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import test from "node:test";
import vm from "node:vm";

async function production(api = 20, attachDuringBuild = false) {
  const nodes = [];
  const operations = [];
  class Controller {
    static initializeWebEngine() {}
    constructor(tag) {
      this.tag = tag;
      this.url = "";
      this.history = [];
    }
    setScrollable(value) {
      operations.push(["scroll", value]);
    }
    setCustomUserAgent(value) {
      this.userAgent = value;
      operations.push(["ua", value]);
    }
    setDownloadDelegate() {}
    loadUrl(url) {
      this.url = url;
      this.history.push(url);
      operations.push(["load", url]);
    }
    loadData(html, _mime, _encoding, base) {
      this.url = base;
      this.history.push(base);
      operations.push(["load", html, base]);
    }
    getUrl() {
      return this.url;
    }
    getTitle() {
      return "title";
    }
    accessBackward() {
      return false;
    }
    accessForward() {
      return false;
    }
    stop() {
      operations.push(["stop", this.tag]);
    }
    runJavaScript() {
      return Promise.resolve("");
    }
  }
  const context = vm.createContext({
    console,
    Map,
    Set,
    Promise,
    Error,
    Number,
    Array,
    Uint8Array,
    setTimeout,
    clearTimeout,
    Color: { Transparent: "transparent" },
    HitTestMode: { Block: 1 },
    Visibility: { Hidden: 0, Visible: 1 },
    RenderMode: { SYNC_RENDER: 1, ASYNC_RENDER: 2 },
    wrapBuilder: (builder) => builder,
  });
  let currentNode;
  context.Web = (parameters) => {
    operations.push(["web", parameters.src, parameters.renderMode]);
    const proxy = new Proxy(
      {},
      {
        get(_target, method) {
          return (...args) => {
            if (method === "runJavaScriptOnDocumentStart" || method === "javaScriptOnDocumentStart")
              operations.push([String(method), args[0]]);
            if (method === "javaScriptAccess") operations.push(["javascript", args[0]]);
            if (method === "onControllerAttached") currentNode.attach = args[0];
            if (method === "managedWebviewAttributes") context.managedWebviewAttributes(...args);
            if (method === "managedWebviewDragEvents") context.managedWebviewDragEvents(...args);
            return proxy;
          };
        },
      },
    );
    context.WebAttributes = proxy;
    return proxy;
  };
  class BuilderNode {
    constructor() {
      this.frame = { owner: this };
      this.disposed = false;
      nodes.push(this);
    }
    build(builder, data) {
      this.data = data;
      this.builder = builder;
      currentNode = this;
      builder(data);
      if (attachDuringBuild) this.attach();
    }
    getFrameNode() {
      return this.frame;
    }
    dispose() {
      this.disposed = true;
      operations.push(["dispose", this.data.id]);
    }
    update(data) {
      this.data = data;
      currentNode = this;
      this.builder(data);
      operations.push(["update", data.id]);
    }
  }
  class AsyncPluginBase {
    attachContext(value) {
      this.context = value;
    }
    getContext() {
      return this.context;
    }
  }
  const cache = new Map();
  async function load(name) {
    if (cache.has(name)) return cache.get(name);
    let source = await readFile(new URL(`../src/main/ets/${name}.ets`, import.meta.url), "utf8");
    if (name === "WebviewPlugin") {
      source = source.replace(
        /import \{([^}]+)\} from "\.\/NativeEmbedding";/,
        (_match, fields) =>
          `import {${fields
            .split(",")
            .filter(
              (field) => !["NativeWebviewSettings", "NativeWebviewData"].includes(field.trim()),
            )
            .join(",")}} from "./NativeEmbedding";`,
      );
      // Execute the production attribute chains/builders. Only ArkUI Stack DSL is
      // replaced by the direct builder used by native embedding (drag overlay off).
      source = source.replace(/@Extend\(Web\)\s*/g, "").replace(/@Builder\s*/g, "");
      source = source.replace(
        /(function managedWebview(?:Attributes|DragEvents)[\s\S]*?\{[\s\S]*?\n\s*)\./g,
        "$1\nWebAttributes.",
      );
      const start = source.indexOf("function BuildWebview(data:");
      const end = source.indexOf("/**\n * Document-start scripts", start);
      source =
        source.slice(0, start) +
        "function BuildWebview(data: ManagedWebview) { BuildDirectWebview(data); }\n\n" +
        source.slice(end);
      source +=
        "\nexport { managedWebviewAttributes, managedWebviewDragEvents, failedNativeRetirements };";
    }
    const stripped = stripTypeScriptTypes(source);
    const names = new Map();
    for (const match of stripped.matchAll(/import\s+([\s\S]*?)\s+from\s+["']([^"']+)["'];/g)) {
      const clause = match[1].trim();
      const fields = [];
      const named = clause.match(/\{([\s\S]*)\}/);
      if (named)
        for (const field of named[1].split(",")) {
          const key = field.trim().split(/\s+as\s+/)[0];
          if (key) fields.push(key);
        }
      if (!clause.startsWith("{") && !clause.startsWith("*")) fields.push("default");
      names.set(match[2], fields);
    }
    const module = new vm.SourceTextModule(stripped, { context });
    cache.set(name, module);
    await module.link(async (specifier) => {
      if (specifier === "./NativeEmbedding") return load("NativeEmbedding");
      return new vm.SyntheticModule(
        names.get(specifier),
        function () {
          for (const key of names.get(specifier)) {
            let value = class {};
            if (key === "default" && specifier === "@ohos.web.webview")
              value = { WebviewController: Controller, WebDownloadDelegate: class {} };
            if (key === "BuilderNode") value = BuilderNode;
            if (key === "AsyncPluginBase") value = AsyncPluginBase;
            if (key === "deviceInfo") value = { sdkApiVersion: api };
            if (key === "hilog") value = { info() {}, warn() {}, error() {} };
            if (key === "WindowManager")
              value = { getInstance: () => ({ getPendingBlur: () => 0, setWebviewFlags() {} }) };
            if (key === "notifyPrimaryWebviewController" || key === "notifyKeySynthesisController")
              value = () => {
                throw new Error("native controller leaked to legacy global map");
              };
            this.setExport(key, value);
          }
        },
        { context },
      );
    });
    return module;
  }
  const module = await load("WebviewPlugin");
  await module.evaluate();
  context.managedWebviewAttributes = module.namespace.managedWebviewAttributes;
  context.managedWebviewDragEvents = module.namespace.managedWebviewDragEvents;
  function host(sessionId) {
    const events = [];
    const receipts = [];
    const borrowed = new Set();
    const mounting = new Set();
    const failures = new Set();
    const state = { autoAttach: true, active: true, cancellation: [] };
    const ctx = {
      sessionId,
      isActive: () => true,
      onCancel: () => () => {},
      getUIContext: () => ({}),
      invokeNativeSyncProcessWide: () => [{ accepted: true, schemes: [] }],
      invokeNativeSync(event, _request, _response, value) {
        if (event === "native-node-ready") {
          assert.equal(_request, "ohos.node.NativeNodeReady");
          assert.equal(_response, "ohos.node.Acknowledgement");
          if (state.rejectReady) throw new Error("attachment failed");
          borrowed.add(value.targetId);
          mounting.add(value.targetId);
          if (state.autoAttach) value.content.owner.attach();
          mounting.delete(value.targetId);
          operations.push([event, value.targetId]);
        } else if (event === "native-node-retiring") {
          assert.equal(_request, "ohos.node.NativeNodeRetiring");
          assert.equal(_response, "ohos.node.Acknowledgement");
          operations.push([event, value.targetId]);
          if (failures.has(value.targetId)) throw new Error("detach failed");
          borrowed.delete(value.targetId);
        } else if (
          event === "native-controller-attached" ||
          event === "native-controller-removed"
        ) {
          assert.equal(_request, "ohos.webview.NativeControllerEvent");
          assert.equal(_response, "ohos.webview.EventAcknowledgement");
          assert.ok(
            borrowed.has(value.targetId),
            "controller dispatch requires an attached target",
          );
          assert.ok(
            !mounting.has(value.targetId),
            "controller dispatch cannot reenter native attach",
          );
          receipts.push({ event, ...value });
          operations.push([event, value.targetId]);
          if (event === "native-controller-removed" && state.rejectRemoval) {
            throw new Error("controller removal failed");
          }
          if (event === "native-controller-attached" && state.closeOnReceipt) {
            plugin.onClosing(ctx);
            operations.push(["rust-destroy"]);
          }
          if (event === "native-controller-attached" && state.cancelOnReceipt) {
            state.active = false;
            for (const listener of state.cancellation) listener();
          }
        } else if (event === "native-event") {
          assert.equal(_request, "ohos.webview.NativeEvent");
          assert.equal(_response, "ohos.webview.EventAcknowledgement");
          events.push(value);
        } else throw new Error(`native flow used legacy event ${event}`);
        return { accepted: true };
      },
    };
    const plugin = new module.namespace.WebviewPlugin();
    plugin.attachContext(ctx);
    plugin.onInstall(ctx);
    const call = {
      ...ctx,
      isActive: () => state.active,
      onCancel: (listener) => {
        state.cancellation.push(listener);
        return () => {
          state.cancellation = state.cancellation.filter((item) => item !== listener);
        };
      },
    };
    const create = (targetId = 7, id = "same") =>
      plugin.invokeAsync(
        "create-native",
        {
          typeName: "ohos.webview.NativeCreateRequest",
          value: {
            targetId,
            webview: {
              id,
              html: "<p>first</p>",
              javascriptEnabled: false,
              userAgent: "initial-agent",
              initializationScripts: [
                { script: "initial-script", scriptRules: ["*"] },
                { script: "second-script", scriptRules: ["*"] },
              ],
            },
            settings: {
              id,
              scrollEnabled: false,
              htmlBaseUrl: "https://base.invalid/",
              injectedJavascript: "after-load",
              javascriptEnabled: true,
              userAgent: "conflicting-extra-agent",
              initializationScripts: [],
            },
          },
        },
        call,
      );
    return {
      plugin,
      ctx,
      call,
      events,
      borrowed,
      receipts,
      failures,
      create,
      state,
      cancel() {
        state.active = false;
        for (const listener of state.cancellation) listener();
      },
    };
  }
  return { host, nodes, operations, failed: module.namespace.failedNativeRetirements };
}

test("API12 and API15+ apply single-source document settings before first load", async () => {
  for (const api of [12, 20]) {
    const { host, operations } = await production(api);
    const owner = host("host");
    await owner.create();
    const documentStart = api >= 15 ? "runJavaScriptOnDocumentStart" : "javaScriptOnDocumentStart";
    const start = operations.findIndex(([name]) => name === documentStart);
    const load = operations.findIndex(([name]) => name === "load");
    assert.ok(start >= 0 && start < load);
    assert.ok(operations.findIndex(([name]) => name === "native-controller-attached") < load);
    assert.ok(
      operations.findIndex(([name]) => name === "native-node-ready") <
        operations.findIndex(([name]) => name === "native-controller-attached"),
    );
    assert.deepEqual(
      Array.from(operations[start][1], (item) => item.script),
      ["initial-script", "second-script"],
    );
    assert.deepEqual(
      operations.find(([name]) => name === "javascript"),
      ["javascript", false],
    );
    assert.deepEqual(
      operations.find(([name]) => name === "ua"),
      ["ua", "initial-agent"],
    );
    assert.ok(operations.findIndex(([name]) => name === "scroll") < load);
    assert.equal(operations[load][2], "https://base.invalid/");
  }
});

test("two Hosts share business ID while retired targets cannot emit", async () => {
  const { host, nodes } = await production();
  const a = host("a");
  const b = host("b");
  await a.create();
  await b.create();
  const old = nodes[0].data;
  await a.plugin.invokeAsync(
    "remove",
    { typeName: "ohos.webview.ControllerRequest", value: { id: "same" } },
    a.ctx,
  );
  await a.create(8);
  old.nativeNotify("title");
  nodes[2].data.nativeNotify("title");
  nodes[1].data.nativeNotify("title");
  assert.equal(a.events.length, 1);
  assert.equal(a.events[0].targetId, 8);
  assert.equal(b.events.length, 1);
  assert.equal(b.events[0].targetId, 7);
});

test("closing retires synchronously then disposal waits for all page tasks", async () => {
  const { host, nodes } = await production();
  const owner = host("closing");
  await owner.create();
  const node = nodes[0];
  node.data.javascriptEnabled = true;
  let finish;
  node.data.controller.runJavaScript = () =>
    new Promise((resolve) => {
      finish = resolve;
    });
  node.data.nativePageFinished();
  assert.equal(node.data.nativeTasks.size, 1);
  assert.equal(owner.plugin.onClosing(owner.ctx), undefined);
  assert.equal(owner.borrowed.size, 0);
  assert.equal(node.disposed, false);
  const disposed = owner.plugin.onDispose(owner.ctx);
  await Promise.resolve();
  assert.equal(node.disposed, false);
  finish("");
  await disposed;
  assert.equal(node.disposed, true);
  assert.equal(owner.events.length, 0);
});

test("failed retirement retains owner and does not block other entry cleanup", async () => {
  const { host, nodes, failed } = await production();
  const owner = host("failure");
  await owner.create(7, "first");
  await owner.create(8, "second");
  owner.failures.add(7);
  assert.throws(() => owner.plugin.onClosing(owner.ctx), /detach failed/);
  assert.equal(owner.borrowed.has(8), false);
  await assert.rejects(owner.plugin.onDispose(owner.ctx), /detach failed/);
  assert.equal(nodes[0].disposed, false);
  assert.equal(nodes[1].disposed, true);
  assert.equal(failed.size, 1);
});

test("same-ID replacement serializes teardown before attaching a fresh target", async () => {
  const { host, nodes } = await production();
  const owner = host("serial");
  const results = await Promise.allSettled([owner.create(7), owner.create(8)]);
  assert.equal(results[0].status, "fulfilled");
  assert.equal(results[1].status, "fulfilled");
  assert.equal(nodes.length, 2);
  assert.equal(nodes[0].disposed, true);
  assert.equal(nodes[1].data.nativeTarget, 8);
});

test("cancellation after native mount retires through active plugin context", async () => {
  const { host, nodes } = await production();
  const owner = host("cancel");
  owner.state.autoAttach = false;
  const creation = owner.create();
  for (let turn = 0; turn < 20 && owner.borrowed.size === 0; turn++) await Promise.resolve();
  assert.equal(owner.borrowed.size, 1);
  owner.cancel();
  await assert.rejects(creation, /cancelled|no longer active/);
  assert.equal(owner.borrowed.size, 0);
  assert.equal(nodes[0].disposed, true);
});

test("native settings retain controller/history and leave creation options unchanged", async () => {
  const { host, nodes, operations } = await production(20);
  const owner = host("options");
  await owner.create();
  const node = nodes[0],
    controller = node.data.controller;
  const loads = controller.history.length;
  assert.equal(nodes.length, 1);
  assert.equal(node.data.controller, controller);
  assert.equal(controller.history.length, loads);
  assert.equal(node.data.javascriptEnabled, false);
  assert.equal(node.data.userAgent, "initial-agent");
  assert.equal(node.data.initializationScripts[0].script, "initial-script");
  node.attach();
  assert.equal(controller.history.length, loads);
  assert.ok(
    operations.some(
      ([name, value]) =>
        name === "runJavaScriptOnDocumentStart" && value[0].script === "initial-script",
    ),
  );
  await owner.plugin.invokeAsync(
    "configure-native",
    {
      typeName: "ohos.webview.NativeSettings",
      value: { id: "same", scrollEnabled: true, htmlBaseUrl: "https://updated.invalid/" },
    },
    owner.ctx,
  );
  await owner.plugin.invokeAsync(
    "load-html",
    { typeName: "ohos.webview.ControllerRequest", value: { id: "same", html: "<p>next</p>" } },
    owner.ctx,
  );
  assert.equal(controller.history.at(-1), "https://updated.invalid/");
});
test("replacement and closing send exact controller receipts once using the cleanup context", async () => {
  const { host, operations } = await production();
  const owner = host("receipts");
  await owner.create(7);
  await owner.create(8);
  assert.deepEqual(
    owner.receipts.map((value) => [value.event, value.targetId]),
    [
      ["native-controller-attached", 7],
      ["native-controller-removed", 7],
      ["native-controller-attached", 8],
    ],
  );
  let removed = 0;
  const cleanup = {
    ...owner.ctx,
    invokeNativeSync: (...args) => {
      if (args[0] === "native-controller-removed") removed++;
      return owner.ctx.invokeNativeSync(...args);
    },
  };
  owner.plugin.onClosing(cleanup);
  await owner.plugin.onDispose(cleanup);
  assert.equal(removed, 1);
  assert.equal(owner.receipts.at(-1).event, "native-controller-removed");
  assert.equal(owner.receipts.at(-1).targetId, 8);
  for (const target of [7, 8]) {
    const removed = operations.findIndex(
      ([event, id]) => event === "native-controller-removed" && id === target,
    );
    const retired = operations.findIndex(
      ([event, id]) => event === "native-node-retiring" && id === target,
    );
    assert.ok(removed >= 0 && removed < retired);
  }
});
test("cancellation inside the attach receipt cannot navigate and still removes declarations", async () => {
  const { host, nodes, operations } = await production();
  const owner = host("receipt-cancel");
  owner.state.cancelOnReceipt = true;
  await assert.rejects(owner.create(), /retired|rejected|cancelled|no longer active/);
  assert.equal(
    operations.some(([name]) => name === "load"),
    false,
  );
  assert.deepEqual(
    owner.receipts.map((value) => value.event),
    ["native-controller-attached", "native-controller-removed"],
  );
  assert.equal(nodes[0].disposed, true);
});

test("SDK build callbacks wait for native ready before controller installation and reentrant closing", async () => {
  const { host, nodes, operations } = await production(20, true);
  const owner = host("build-close");
  owner.state.closeOnReceipt = true;
  await assert.rejects(owner.create(), /disposed|retired|rejected|active/);
  assert.equal(
    operations.some(([name]) => name === "load"),
    false,
  );
  assert.deepEqual(
    owner.receipts.map((value) => value.event),
    ["native-controller-attached", "native-controller-removed"],
  );
  const removed = operations.findIndex(([name]) => name === "native-controller-removed");
  const destroyed = operations.findIndex(([name]) => name === "rust-destroy");
  const disposed = operations.findIndex(([name]) => name === "dispose");
  assert.ok(removed < destroyed && destroyed < disposed);
  assert.equal(nodes[0].disposed, true);
});

test("failed controller cleanup retains the native target and allows a safe retry", async () => {
  const { host, nodes } = await production();
  const owner = host("removal-failure");
  await owner.create();
  owner.state.rejectRemoval = true;
  assert.throws(() => owner.plugin.onClosing(owner.ctx), /controller removal failed/);
  assert.equal(owner.borrowed.has(7), true);
  assert.equal(nodes[0].disposed, false);
  owner.state.rejectRemoval = false;
  await owner.plugin.onDispose(owner.ctx);
  assert.equal(owner.borrowed.size, 0);
  assert.equal(nodes[0].disposed, true);
});

test("native creation rejects malformed targets and mismatched named contracts before building", async () => {
  const { host, nodes } = await production();
  const owner = host("invalid");
  const request = {
    targetId: 7,
    webview: { id: "same", html: "<p>first</p>" },
    settings: { id: "same", scrollEnabled: false },
  };
  for (const targetId of [0, -1, 1.5, 0x100000000, "7"]) {
    await assert.rejects(
      owner.plugin.invokeAsync(
        "create-native",
        { typeName: "ohos.webview.NativeCreateRequest", value: { ...request, targetId } },
        owner.ctx,
      ),
      /Invalid native WebView target/,
    );
  }
  await assert.rejects(
    owner.plugin.invokeAsync(
      "create-native",
      { typeName: "ohos.webview.CreateRequest", value: request },
      owner.ctx,
    ),
    /requires ohos.webview.NativeCreateRequest/,
  );
  await assert.rejects(
    owner.plugin.invokeAsync(
      "create-native",
      {
        typeName: "ohos.webview.NativeCreateRequest",
        value: { ...request, settings: { id: "other", scrollEnabled: false } },
      },
      owner.ctx,
    ),
    /controller ID mismatch/,
  );
  assert.equal(nodes.length, 0);
});

test("failed native ready cannot install a controller observed during SDK build", async () => {
  const { host, nodes, operations } = await production(20, true);
  const owner = host("ready-failure");
  owner.state.rejectReady = true;
  await assert.rejects(owner.create(), /attachment failed/);
  assert.equal(owner.receipts.length, 0);
  assert.equal(owner.borrowed.size, 0);
  assert.equal(nodes[0].disposed, true);
  assert.equal(
    operations.some(([event]) => event === "load"),
    false,
  );
});

function updateOptions(owner, value, typeName = "ohos.webview.DocumentOptionsRequest") {
  return owner.plugin.invokeAsync("update-document-options", { typeName, value }, owner.call);
}

test("document options update actual API12/API20 builders before navigation without replacing history", async () => {
  for (const api of [12, 20]) {
    const { host, nodes, operations } = await production(api);
    const owner = host("document-options");
    await owner.create();
    const node = nodes[0],
      controller = node.data.controller;
    const history = controller.history.slice();
    await owner.plugin.invokeAsync(
      "set-user-agent",
      {
        typeName: "ohos.webview.UserAgentRequest",
        value: { id: "same", userAgent: "runtime-agent" },
      },
      owner.call,
    );
    const start = operations.length;
    const options = {
      id: "same",
      javascriptEnabled: true,
      initializationScripts: [
        { script: "first-update", scriptRules: ["*", "nsh-asset://"] },
        { script: "second-update", scriptRules: [] },
      ],
    };
    const updating = updateOptions(owner, options);
    options.initializationScripts[0].script = "mutated-after-validation";
    await updating;
    assert.equal(nodes.length, 1);
    assert.equal(node.data.controller, controller);
    assert.deepEqual(controller.history, history);
    const changes = operations.slice(start);
    assert.ok(changes.some(([name, value]) => name === "javascript" && value === true));
    const attribute = api >= 15 ? "runJavaScriptOnDocumentStart" : "javaScriptOnDocumentStart";
    const scripts = changes.find(([name]) => name === attribute)[1];
    assert.deepEqual(
      Array.from(scripts, (item) => item.script),
      ["first-update", "second-update"],
    );
    assert.deepEqual(Array.from(scripts[0].scriptRules), ["*", "nsh-asset://"]);
    node.attach(); // SDK may deliver the callback again after BuilderNode.update.
    assert.equal(controller.userAgent, "runtime-agent");
    assert.equal(operations.filter(([name]) => name === "ua").length, 2);
    assert.equal(
      owner.receipts.filter(({ event }) => event === "native-controller-attached").length,
      1,
    );
    await owner.plugin.invokeAsync(
      "load-url",
      {
        typeName: "ohos.webview.ControllerRequest",
        value: { id: "same", url: "https://next.invalid/" },
      },
      owner.call,
    );
    assert.ok(
      operations.findLastIndex(([name]) => name === "update") <
        operations.findLastIndex(([name]) => name === "load"),
    );
    await updateOptions(owner, { id: "same", javascriptEnabled: false, initializationScripts: [] });
    assert.deepEqual(operations.filter(([name]) => name === "javascript").at(-1), [
      "javascript",
      false,
    ]);
    assert.equal(operations.filter(([name]) => name === attribute).at(-1)[1].length, 0);
    const count = controller.history.length;
    await updateOptions(owner, { id: "same" });
    assert.equal(node.data.javascriptEnabled, false);
    assert.equal(node.data.initializationScripts.length, 0);
    assert.equal(controller.history.length, count);
  }
});

test("complete document payload validation rejects malformed updates before any mutation", async () => {
  const { host, nodes, operations } = await production();
  const owner = host("invalid-options");
  await owner.create();
  const data = nodes[0].data,
    before = operations.length;
  const invalid = [
    { id: "same", javascriptEnabled: "true" },
    { id: "same", javascriptEnabled: true, initializationScripts: {} },
    { id: "same", javascriptEnabled: true, initializationScripts: [null] },
    {
      id: "same",
      javascriptEnabled: true,
      initializationScripts: [{ script: 12, scriptRules: [] }],
    },
    {
      id: "same",
      javascriptEnabled: true,
      initializationScripts: [{ script: "valid", scriptRules: [2] }],
    },
    { id: "same", javascriptEnabled: true, initializationScripts: new Array(1) },
    { id: 7, javascriptEnabled: true },
  ];
  for (const value of invalid) await assert.rejects(updateOptions(owner, value));
  await assert.rejects(
    updateOptions(owner, { id: "same" }, "wrong.type"),
    /DocumentOptionsRequest/,
  );
  await assert.rejects(updateOptions(owner, { id: "unknown", javascriptEnabled: true }), /Unknown/);
  assert.equal(data.javascriptEnabled, false);
  assert.equal(data.initializationScripts[0].script, "initial-script");
  assert.equal(operations.length, before);
  await assert.rejects(
    owner.plugin.invokeAsync(
      "create-native",
      {
        typeName: "ohos.webview.NativeCreateRequest",
        value: {
          targetId: 8,
          webview: {
            id: "invalid-create",
            html: "page",
            initializationScripts: [{ script: "ok", scriptRules: [9] }],
          },
          settings: { id: "invalid-create", scrollEnabled: true },
        },
      },
      owner.call,
    ),
    /rules/,
  );
  assert.equal(nodes.length, 1);
});

test("BuilderNode update failure rejects the document-options acknowledgement", async () => {
  const { host, nodes } = await production();
  const owner = host("update-failure");
  await owner.create();
  const node = nodes[0],
    update = node.update.bind(node);
  node.update = () => {
    throw new Error("SDK update failed");
  };
  const options = {
    id: "same",
    javascriptEnabled: true,
    initializationScripts: [{ script: "retry-script", scriptRules: ["*"] }],
  };
  await assert.rejects(updateOptions(owner, options), /SDK update failed/);
  assert.equal(node.disposed, false);
  assert.equal(node.data.controller.history.length, 1);
  assert.equal(node.data.javascriptEnabled, false);
  assert.equal(node.data.initializationScripts[0].script, "initial-script");
  node.update = update;
  await updateOptions(owner, options);
  assert.equal(node.data.javascriptEnabled, true);
  assert.equal(node.data.initializationScripts[0].script, "retry-script");
});

test("closing or disposal during controller readiness cannot update the retired entry", async () => {
  for (const dispose of [false, true]) {
    const { host, nodes, operations } = await production();
    const owner = host("retired-options");
    await owner.create();
    const before = operations.filter(([name]) => name === "update").length;
    const pending = updateOptions(owner, { id: "same", javascriptEnabled: true });
    const rejected = assert.rejects(pending, /retired|disposed/);
    owner.plugin.onClosing(owner.ctx);
    if (dispose) await owner.plugin.onDispose(owner.ctx);
    await rejected;
    assert.equal(nodes[0].data.javascriptEnabled, false);
    assert.equal(operations.filter(([name]) => name === "update").length, before);
  }
});

test("controller identity is rechecked after the readiness await", async () => {
  const { host, nodes } = await production();
  const owner = host("old-options"),
    replacement = host("replacement-options");
  await owner.create(7);
  await replacement.create(8);
  const entries = owner.plugin.surface.entries;
  const old = entries.get("same");
  const pending = updateOptions(owner, { id: "same", javascriptEnabled: true });
  // Install another actual production entry during the async readiness boundary.
  entries.set("same", replacement.plugin.surface.entries.get("same"));
  await assert.rejects(pending, /replaced/);
  assert.equal(nodes[0].data.javascriptEnabled, false);
  assert.equal(nodes[1].data.javascriptEnabled, false);
  entries.set("same", old);
});

test("cancelled options do not reach the SDK after the readiness await", async () => {
  const { host, nodes } = await production();
  const owner = host("cancelled-options");
  await owner.create();
  const pending = updateOptions(owner, { id: "same", javascriptEnabled: true });
  owner.cancel();
  await assert.rejects(pending, /no longer active/);
  assert.equal(nodes[0].data.javascriptEnabled, false);
});

test("options recheck disposal between controllerEntry completion and caller continuation", async () => {
  const { host, nodes } = await production();
  const owner = host("continuation-dispose");
  await owner.create();
  const pending = updateOptions(owner, { id: "same", javascriptEnabled: true });
  let disposal;
  queueMicrotask(() => {
    disposal = owner.plugin.onDispose(owner.ctx);
  });
  await assert.rejects(pending, /disposed|retired/);
  await disposal;
  assert.equal(nodes[0].data.javascriptEnabled, false);
});

test("reentrant SDK update teardown cannot return a successful acknowledgement", async () => {
  const { host, nodes } = await production();
  const owner = host("update-reentry");
  await owner.create();
  const node = nodes[0],
    update = node.update.bind(node);
  node.update = (data) => {
    update(data);
    owner.plugin.onClosing(owner.ctx);
  };
  await assert.rejects(
    updateOptions(owner, { id: "same", javascriptEnabled: true }),
    /retired|disposed/,
  );
  assert.equal(owner.borrowed.size, 0);
});
