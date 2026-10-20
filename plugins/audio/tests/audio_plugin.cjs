const assert = require("node:assert/strict"),
  fs = require("node:fs"),
  path = require("node:path"),
  vm = require("node:vm");
const ts = require(process.argv[2] || "typescript");
const settle = async () => {
  for (let i = 0; i < 40; i++) await Promise.resolve();
};
const deferred = () => {
  let resolve;
  const promise = new Promise((done) => (resolve = done));
  return { promise, resolve };
};
function compile(file, imports) {
  const source = fs.readFileSync(path.join(__dirname, "../src/main/ets", file), "utf8");
  const result = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true,
  });
  assert.equal(
    (result.diagnostics || []).filter((d) => d.category === ts.DiagnosticCategory.Error).length,
    0,
  );
  const scope = {
    exports: {},
    Promise,
    console: { warn: (message) => warnings.push(message), info: () => {} },
    require: (name) => {
      assert.ok(name in imports, name);
      return imports[name];
    },
  };
  vm.runInNewContext(result.outputText, scope, { filename: file });
  return scope.exports;
}
const warnings = [],
  closed = [],
  created = [],
  duplicates = [],
  events = [];
const sessions = compile("player_session.ets", {});
class NativePlayer {
  state = "idle";
  listeners = {};
  calls = [];
  releases = 0;
  on(kind, callback) {
    this.listeners[kind] = callback;
  }
  emit(kind, value) {
    if (kind === "stateChange") this.state = value;
    this.listeners[kind]?.(value);
  }
  set fdSrc(value) {
    this.calls.push(["source", value.fd]);
    this.emit("stateChange", "initialized");
  }
  prepare() {
    this.calls.push(["prepare"]);
    this.emit("stateChange", "prepared");
    return Promise.resolve();
  }
  setVolume(value) {
    this.calls.push(["volume", value]);
    this.emit("volumeChange", value);
  }
  seek(value) {
    this.calls.push(["seek", value]);
    this.emit("seekDone", value);
  }
  play() {
    this.calls.push(["play"]);
    this.emit("stateChange", "playing");
    return Promise.resolve();
  }
  release() {
    this.releases++;
    this.emit("stateChange", "released");
    return this.releasePromise || Promise.resolve();
  }
}
const { AudioPlugin } = compile("AudioPlugin.ets", {
  "@ohos.multimedia.media": {
    default: {
      createAVPlayer: () => {
        const player = new NativePlayer();
        created.push(player);
        return Promise.resolve(player);
      },
    },
  },
  "@ohos.multimedia.audio": { default: { StreamUsage: { STREAM_USAGE_NOTIFICATION: 7 } } },
  "@ohos.file.fs": {
    default: {
      closeSync: (fd) => {
        assert.ok(!closed.includes(fd));
        closed.push(fd);
      },
    },
  },
  "@ohos-rs/ability": {
    AsyncPluginBase: class {},
    expectBridgeRequestType: (payload, id, action, type) => {
      assert.equal(type, payload.typeName);
      return payload.value;
    },
  },
  "./player_session": sessions,
});
let active = true,
  nextFd = 100;
const context = {
  isActive: () => active,
  invokeNativeSync: (event, request, response, value) => {
    if (event === "duplicate") {
      assert.equal(response, "std.i32");
      duplicates.push(value.fd);
      return nextFd++;
    }
    assert.equal(event, "playback");
    events.push(value);
    return true;
  },
};
const request = (plugin, changes = {}) =>
  plugin.invokeAsync(
    "update",
    {
      typeName: "ohos.audio.UpdateRequest",
      value: {
        player: "application",
        replace: false,
        release: false,
        play: true,
        volume: 0.5,
        reportErrors: true,
        label: "bell.wav",
        diagnostics: true,
        ...changes,
      },
    },
    context,
  );
(async () => {
  let cases = 0;
  const plugin = new AudioPlugin();
  const accepted = request(plugin, { replace: true, sourceFd: 81, volume: 0.25 });
  assert.deepEqual(duplicates, [81]);
  assert.equal(closed.length, 0);
  assert.equal((await accepted).value.accepted, true);
  await settle();
  assert.equal(created.length, 1);
  assert.deepEqual(created[0].calls, [
    ["source", 100],
    ["prepare"],
    ["volume", 0.25],
    ["seek", 0],
    ["play"],
  ]);
  cases++;
  await request(plugin, { volume: 0.75, reportErrors: false });
  await settle();
  assert.equal(created.length, 1);
  assert.deepEqual(created[0].calls.slice(-2), [
    ["volume", 0.75],
    ["seek", 0],
  ]);
  cases++;
  created[0].emit("stateChange", "completed");
  await request(plugin);
  await settle();
  assert.deepEqual(created[0].calls.slice(-3), [["volume", 0.5], ["seek", 0], ["play"]]);
  cases++;
  created[0].emit("error", new Error("decoder"));
  assert.equal(warnings.filter((m) => m.includes("decoder")).length, 1);
  cases++;
  const delayed = deferred();
  created[0].releasePromise = delayed.promise;
  await request(plugin, { replace: true, sourceFd: 82, volume: 1 });
  await settle();
  assert.equal(created.length, 1);
  assert.equal(closed.length, 0);
  assert.deepEqual(duplicates, [81, 82]);
  await request(plugin, { volume: 0.125 });
  delayed.resolve();
  await settle();
  assert.equal(created.length, 2);
  assert.deepEqual(closed, [100]);
  assert.deepEqual(created[1].calls.slice(-3), [["volume", 0.125], ["seek", 0], ["play"]]);
  cases++;
  const release = deferred();
  created[1].releasePromise = release.promise;
  let acknowledged = false;
  const clear = request(plugin, { replace: true, play: false }).then(() => (acknowledged = true));
  await settle();
  assert.equal(closed.length, 1);
  assert.equal(acknowledged, false);
  let disposed = false;
  const cleanup = plugin.onDispose().then(() => (disposed = true));
  await settle();
  assert.equal(disposed, false);
  release.resolve();
  await cleanup;
  await clear;
  assert.deepEqual(closed, [100, 101]);
  cases++;
  await assert.rejects(request(plugin, { volume: NaN }));
  await assert.rejects(request(plugin, { sourceFd: 22 }));
  await assert.rejects(request(plugin, { release: true, sourceFd: 22, replace: true }));
  assert.equal(duplicates.length, 2);
  cases++;
  active = false;
  await assert.rejects(request(plugin, { replace: true, sourceFd: 99 }));
  assert.equal(duplicates.length, 2);
  cases++;
  assert.equal(created[0].releases, 1);
  assert.equal(created[1].releases, 1);
  assert.ok(events.some((e) => e.event === "created"));
  assert.ok(events.some((e) => e.event === "seek" && e.value === 0));
  console.log(
    JSON.stringify({
      all_passed: true,
      plugin_cases: cases,
      players: created.length,
      duplicated: duplicates.length,
      closed: closed.length,
    }),
  );
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
