import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import test from "node:test";
const source = await readFile(
  new URL("../src/main/ets/VideoOperations.ets", import.meta.url),
  "utf8",
);
const { VideoOperations } = await import(
  `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString("base64")}`
);
function deferred() {
  let resolve;
  const promise = new Promise((r) => {
    resolve = r;
  });
  return { promise, resolve };
}
test("release waits for the active operation and cancels queued mutations", async () => {
  const queue = new VideoOperations(),
    active = deferred(),
    order = [];
  const first = queue.run(async () => {
    order.push("reset");
    await active.promise;
    order.push("reset-done");
  });
  await Promise.resolve();
  const queued = queue.run(async () => {
    assert.fail("queued mutation ran during closing");
  });
  const closing = queue.close(async () => {
    order.push("release");
  });
  const again = queue.close(async () => assert.fail("duplicate release"));
  assert.equal(again, closing);
  assert.deepEqual(order, ["reset"]);
  active.resolve();
  await first;
  await assert.rejects(queued, /disposed/);
  await closing;
  assert.deepEqual(order, ["reset", "reset-done", "release"]);
  await assert.rejects(
    queue.run(async () => {}),
    /disposed/,
  );
});
test("an operation failure does not skip release or another player's work", async () => {
  const a = new VideoOperations(),
    b = new VideoOperations();
  await assert.rejects(
    a.run(async () => {
      throw new Error("reset failure");
    }),
    /reset failure/,
  );
  let releases = 0;
  await b.run(async () => {});
  await Promise.all([
    a.close(async () => {
      releases++;
    }),
    b.close(async () => {
      releases++;
    }),
  ]);
  assert.equal(releases, 2);
});
const pluginSource = await readFile(
  new URL("../src/main/ets/VideoPlugin.ets", import.meta.url),
  "utf8",
);
const pluginClass = pluginSource.slice(pluginSource.indexOf("export class VideoPlugin"));
const { VideoPlugin } = await import(
  `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes("class AsyncPluginBase {}\n" + pluginClass)).toString("base64")}`
);
test("plugin closing detaches every entry synchronously and dispose awaits all releases", async () => {
  const plugin = new VideoPlugin(),
    finish = deferred(),
    order = [];
  plugin.entries.set("bad", {
    close: () => {
      order.push("detach-bad");
      throw new Error("detach failed");
    },
    dispose: async () => {
      throw new Error("release failed");
    },
  });
  plugin.entries.set("good", {
    close: () => order.push("detach-good"),
    dispose: async () => {
      await finish.promise;
      order.push("released-good");
    },
  });
  assert.throws(() => plugin.onClosing({}), /detach failed/);
  assert.deepEqual(order, ["detach-bad", "detach-good"]);
  let completed = false;
  const closing = plugin.onDispose({}).finally(() => {
    completed = true;
  });
  closing.catch(() => {});
  await Promise.resolve();
  assert.equal(completed, false);
  finish.resolve();
  await assert.rejects(closing, /detach failed/);
  assert.equal(order.at(-1), "released-good");
  assert.equal(plugin.entries.size, 0);
});
const operationsSource = await readFile(
  new URL("../src/main/ets/VideoOperations.ets", import.meta.url),
  "utf8",
);
const ownerSource = pluginSource.slice(
  pluginSource.indexOf("class VideoEntry"),
  pluginSource.indexOf("export class VideoPlugin"),
);
const stubs = `class XComponentController {} class BuilderNode { build() {} getFrameNode() { return {}; } dispose() { globalThis.videoOrder.push("node-dispose"); } }
function wrapBuilder(value) { return value; } function VideoContent() {}
class Ready { constructor(targetId, content) { this.targetId = targetId; this.content = content; } }
class Acknowledgement { accepted = true; }
class Retiring { constructor(targetId) { this.targetId = targetId; } }
const failedNativeRetirements = new Set();`;
const { VideoEntry, VideoPlugin: RealVideoPlugin } = await import(
  `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(operationsSource + stubs + "class AsyncPluginBase {} function parseSettings(value) { return value; }" + ownerSource + pluginClass + "\nexport { VideoEntry }; ")).toString("base64")}`
);
test("the actual owner detaches before Rust shutdown and releases only after active reset", async () => {
  const order = [];
  globalThis.videoOrder = order;
  const reset = deferred();
  let scopeActive = true;
  const context = {
    getUIContext: () => ({}),
    invokeNativeSync: () => {
      assert.equal(scopeActive, true);
      order.push("detach");
      return { accepted: true };
    },
  };
  const entry = new VideoEntry(11, { id: "video" }, context);
  entry.mounted = true;
  entry.player = {
    reset: async () => {
      order.push("reset");
      await reset.promise;
    },
    release: async () => {
      order.push("release");
    },
  };
  const source = entry.source("https://example.test/video.mp4");
  await Promise.resolve();
  entry.close(context);
  scopeActive = false;
  order.push("rust-destroy");
  assert.deepEqual(order, ["reset", "detach", "rust-destroy"]);
  reset.resolve();
  await source;
  await entry.dispose({ invokeNativeSync: () => assert.fail("cached cleanup used") });
  assert.deepEqual(order, ["reset", "detach", "rust-destroy", "release", "node-dispose"]);
});
test("failed native detach retains its builder while completing independent player release", async () => {
  const order = [];
  globalThis.videoOrder = order;
  const context = {
    getUIContext: () => ({}),
    invokeNativeSync: () => {
      order.push("detach");
      return { accepted: false };
    },
  };
  const entry = new VideoEntry(12, { id: "video" }, context);
  entry.mounted = true;
  entry.player = {
    release: async () => {
      order.push("release");
    },
  };
  assert.throws(() => entry.close(context), /rejected/);
  await assert.rejects(entry.dispose(context), /rejected/);
  assert.deepEqual(order, ["detach", "release"]);
});

test("cancelled creation after mount retires through the installed plugin context", async () => {
  const order = [];
  globalThis.videoOrder = order;
  let active = true;
  const plugin = new RealVideoPlugin();
  const context = {
    getUIContext: () => ({}),
    invokeNativeSync: (name) => {
      order.push(name);
      return { accepted: true };
    },
  };
  plugin.getContext = () => context;
  const call = {
    isActive: () => active,
    onCancel: () => () => {},
    invokeNativeSync: () => assert.fail("cancelled call used for cleanup"),
  };
  const creating = plugin.invokeAsync(
    "create",
    {
      typeName: "ohos.video.CreateRequest",
      value: { targetId: 30, settings: { id: "cancelled" } },
    },
    call,
  );
  await Promise.resolve();
  active = false;
  plugin.entries.get("cancelled").surfaceLoaded();
  await assert.rejects(creating, /cancelled/);
  assert.deepEqual(order, ["native-node-ready", "native-node-retiring", "node-dispose"]);
});
test("a player created during cancellation stays owned when release fails", async () => {
  const order = [];
  globalThis.videoOrder = order;
  const made = deferred();
  const player = {
    release: async () => {
      throw new Error("release failed");
    },
  };
  globalThis.media = { createAVPlayer: () => made.promise };
  let active = true;
  const plugin = new RealVideoPlugin();
  plugin.getContext = () => ({
    getUIContext: () => ({}),
    invokeNativeSync: () => ({ accepted: true }),
  });
  const creating = plugin.invokeAsync(
    "create",
    {
      typeName: "ohos.video.CreateRequest",
      value: { targetId: 31, settings: { id: "late-player" } },
    },
    { isActive: () => active, onCancel: () => () => {} },
  );
  await Promise.resolve();
  const entry = plugin.entries.get("late-player");
  entry.surfaceLoaded();
  await Promise.resolve();
  active = false;
  made.resolve(player);
  await assert.rejects(creating, /release failed/);
  assert.equal(entry.player, player);
  assert.deepEqual(order, []);
});
test("unlink failure retains the temporary path and rejects resource completion", async () => {
  const order = [];
  globalThis.videoOrder = order;
  globalThis.fs = {
    closeSync: () => order.push("fd-close"),
    unlinkSync: () => {
      throw new Error("unlink failed");
    },
  };
  const entry = new VideoEntry(32, { id: "temporary" }, { getUIContext: () => ({}) });
  entry.file = { fd: 10 };
  entry.temporaryPath = "/cache/resource";
  await assert.rejects(entry.dispose({}), /unlink failed/);
  assert.equal(entry.temporaryPath, "/cache/resource");
  assert.deepEqual(order, ["fd-close"]);
});
