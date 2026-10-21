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
          borrowed.add(value.targetId);
          if (state.autoAttach) value.content.owner.attach();
        } else if (event === "native-node-retiring") {
          if (failures.has(value.targetId)) throw new Error("detach failed");
          borrowed.delete(value.targetId);
        } else if (
          event === "native-controller-attached" ||
          event === "native-controller-removed"
        ) {
          receipts.push({ event, ...value });
          operations.push([event, value.generation]);
          if (event === "native-controller-attached" && state.closeOnReceipt) {
            plugin.onClosing(ctx);
            operations.push(["rust-destroy"]);
          }
          if (event === "native-controller-attached" && state.cancelOnReceipt) {
            state.active = false;
            for (const listener of state.cancellation) listener();
          }
        } else if (event === "native-event") events.push(value);
        else throw new Error(`native flow used legacy event ${event}`);
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
    const create = (generation = 1, id = "same", targetId = 7) =>
      plugin.invokeAsync(
        "create-native",
        {
          typeName: "ohos.webview.NativeCreateRequest",
          value: {
            generation,
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

test("two Hosts share business ID while retired generations cannot emit", async () => {
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
  await a.create(2);
  old.nativeNotify("title");
  nodes[2].data.nativeNotify("title");
  nodes[1].data.nativeNotify("title");
  assert.equal(a.events.length, 1);
  assert.equal(a.events[0].generation, 2);
  assert.equal(b.events.length, 1);
  assert.equal(b.events[0].generation, 1);
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
  await owner.create(1, "first", 7);
  await owner.create(2, "second", 8);
  owner.failures.add(7);
  assert.throws(() => owner.plugin.onClosing(owner.ctx), /detach failed/);
  assert.equal(owner.borrowed.has(8), false);
  await assert.rejects(owner.plugin.onDispose(owner.ctx), /detach failed/);
  assert.equal(nodes[0].disposed, false);
  assert.equal(nodes[1].disposed, true);
  assert.equal(failed.size, 1);
});

test("superseded same-ID creation never creates a second unmanaged owner", async () => {
  const { host, nodes } = await production();
  const owner = host("serial");
  const results = await Promise.allSettled([owner.create(1), owner.create(2)]);
  assert.equal(results[0].status, "rejected");
  assert.equal(results[1].status, "fulfilled");
  assert.equal(nodes.length, 1);
  assert.equal(nodes[0].data.nativeGeneration, 2);
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

test("document option patches retain the live controller/history and share initial fields", async () => {
  const { host, nodes, operations } = await production(20);
  const owner = host("options");
  await owner.create();
  const node = nodes[0],
    controller = node.data.controller;
  const loads = controller.history.length;
  await owner.plugin.invokeAsync(
    "update-document-options",
    {
      typeName: "ohos.webview.DocumentOptionsRequest",
      value: {
        id: "same",
        javascriptEnabled: true,
        userAgent: "updated-agent",
        initializationScripts: [{ script: "updated-script", scriptRules: ["*"] }],
      },
    },
    owner.ctx,
  );
  assert.equal(nodes.length, 1);
  assert.equal(node.data.controller, controller);
  assert.equal(controller.history.length, loads);
  assert.equal(node.data.javascriptEnabled, true);
  assert.equal(node.data.userAgent, "updated-agent");
  assert.equal(node.data.initializationScripts[0].script, "updated-script");
  node.attach();
  assert.equal(controller.history.length, loads);
  assert.ok(
    operations.some(
      ([name, value]) =>
        name === "runJavaScriptOnDocumentStart" && value[0].script === "updated-script",
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
  const { host } = await production();
  const owner = host("receipts");
  await owner.create(1);
  await owner.create(2);
  assert.deepEqual(
    owner.receipts.map((value) => [value.event, value.generation]),
    [
      ["native-controller-attached", 1],
      ["native-controller-removed", 1],
      ["native-controller-attached", 2],
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
  assert.equal(owner.receipts.at(-1).generation, 2);
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

test("reentrant closing during SDK build removes controller declarations before native shutdown", async () => {
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
