const assert = require("node:assert/strict"),
  fs = require("node:fs"),
  path = require("node:path"),
  vm = require("node:vm");
const { test } = require("node:test");
const sdk = process.env.OHOS_SDK_HOME;
if (!sdk) throw new Error("Set OHOS_SDK_HOME to the SDK directory containing ets/.");
const ts = require(path.join(sdk, "ets/build-tools/ets-loader/node_modules/typescript"));
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
  duplicates = [];
let nextFd = 100,
  duplicateFailure,
  creationFailure,
  creationTask,
  rendererFailure,
  sourceFailure,
  prepareFailure,
  playFailure,
  releaseFailure;
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
    if (sourceFailure) throw sourceFailure;
    this.calls.push(["source", value.fd]);
    this.emit("stateChange", "initialized");
  }
  prepare() {
    if (prepareFailure) return Promise.reject(prepareFailure);
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
    if (playFailure) return Promise.reject(playFailure);
    this.calls.push(["play"]);
    this.emit("stateChange", "playing");
    return Promise.resolve();
  }
  release() {
    this.releases++;
    this.emit("stateChange", "released");
    if (releaseFailure) return Promise.reject(releaseFailure);
    return this.releasePromise || Promise.resolve();
  }
  set audioRendererInfo(value) {
    if (rendererFailure) throw rendererFailure;
    this.rendererInfo = value;
  }
}
const { AudioPlugin } = compile("AudioPlugin.ets", {
  "@ohos.multimedia.media": {
    default: {
      createAVPlayer: () => {
        if (creationFailure) return Promise.reject(creationFailure);
        const player = new NativePlayer();
        created.push(player);
        return creationTask ? creationTask.promise.then(() => player) : Promise.resolve(player);
      },
    },
  },
  "@ohos.multimedia.audio": { default: { StreamUsage: { STREAM_USAGE_NOTIFICATION: 7 } } },
  "@ohos.file.fs": {
    default: {
      dup: (fd) => {
        if (duplicateFailure) throw duplicateFailure;
        duplicates.push(fd);
        return { fd: nextFd++ };
      },
      closeSync: (file) => {
        assert.equal(typeof file.fd, "number");
        assert.ok(!closed.includes(file.fd));
        closed.push(file.fd);
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
let active = true;
const context = {
  isActive: () => active,
  invokeNativeSync: () => {
    assert.fail("Audio must not invoke reverse bridge events");
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
        ...changes,
      },
    },
    context,
  );
test("audio plugin owns SDK descriptors without reverse bridge events", async () => {
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
  assert.deepEqual(Object.keys(created[0].listeners).sort(), ["error", "stateChange"]);
  created[0].emit("seekDone", 0);
  created[0].emit("volumeChange", 0.5);
  created[0].emit("timeUpdate", 10);
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
  active = true;
  {
    const plugin = new AudioPlugin();
    await request(plugin, { replace: true, sourceFd: 83 });
    await settle();
    const player = created.at(-1);
    const sdkError = Object.assign(new Error("Too many open files"), { code: 13900022 });
    duplicateFailure = sdkError;
    await assert.rejects(request(plugin, { replace: true, sourceFd: 84 }), (e) => e === sdkError);
    duplicateFailure = undefined;
    assert.equal(player.releases, 0);
    await request(plugin);
    await settle();
    assert.equal(player.calls.filter((c) => c[0] === "seek").length, 2);
    await plugin.onDispose();
    assert.equal(player.releases, 1);
    cases++;
  }
  {
    const plugin = new AudioPlugin();
    creationTask = deferred();
    await request(plugin, { replace: true, sourceFd: 85 });
    await settle();
    const player = created.at(-1);
    const cleanup = plugin.onDispose();
    const before = closed.length;
    await settle();
    assert.equal(closed.length, before);
    creationTask.resolve();
    creationTask = undefined;
    await cleanup;
    assert.equal(closed.length, before + 1);
    assert.equal(player.releases, 1);
    assert.deepEqual(player.calls, []);
    await plugin.onDispose();
    assert.equal(player.releases, 1);
    cases++;
  }
  {
    const plugin = new AudioPlugin();
    await request(plugin, { replace: true, sourceFd: 86 });
    await settle();
    const player = created.at(-1);
    const releasing = deferred();
    player.releasePromise = releasing.promise;
    const before = closed.length;
    const clear = request(plugin, { release: true, play: false });
    active = false;
    releasing.resolve();
    await assert.rejects(clear, /no longer active/);
    assert.equal(closed.length, before + 1);
    await plugin.onDispose();
    active = true;
    cases++;
  }
  {
    const plugin = new AudioPlugin();
    await request(plugin, { replace: true, sourceFd: 88 });
    await settle();
    const player = created.at(-1);
    const releasing = deferred();
    player.releasePromise = releasing.promise;
    await request(plugin, { replace: true, sourceFd: 89 });
    const before = closed.length;
    const count = created.length;
    const cleanup = plugin.onDispose();
    await settle();
    assert.equal(closed.length, before);
    releasing.resolve();
    await cleanup;
    assert.equal(closed.length, before + 2);
    assert.equal(created.length, count);
    assert.equal(player.releases, 1);
    cases++;
  }
  for (const failure of ["create", "source", "renderer", "prepare", "play", "decoder", "release"]) {
    const plugin = new AudioPlugin();
    const error = new Error(`${failure} SDK failure`);
    creationFailure = failure === "create" ? error : undefined;
    sourceFailure = failure === "source" ? error : undefined;
    rendererFailure = failure === "renderer" ? error : undefined;
    prepareFailure = failure === "prepare" ? error : undefined;
    playFailure = failure === "play" ? error : undefined;
    const before = closed.length;
    await request(plugin, { replace: true, sourceFd: 87 });
    await settle();
    if (failure === "decoder") {
      created.at(-1).emit("error", error);
      await settle();
    }
    if (failure === "release") {
      releaseFailure = error;
    } else {
      assert.equal(closed.length, before + 1, failure);
    }
    await plugin.onDispose();
    assert.equal(closed.length, before + 1, failure);
    assert.ok(
      warnings.some((message) => message.includes(error.message)),
      failure,
    );
    if (failure !== "create") assert.equal(created.at(-1).releases, 1, failure);
    creationFailure =
      sourceFailure =
      rendererFailure =
      prepareFailure =
      playFailure =
      releaseFailure =
        undefined;
    cases++;
  }
  assert.equal(duplicates.length, closed.length);
  console.log(
    JSON.stringify({
      all_passed: true,
      plugin_cases: cases,
      players: created.length,
      duplicated: duplicates.length,
      closed: closed.length,
    }),
  );
});
