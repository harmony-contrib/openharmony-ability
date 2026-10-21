// Execute the production ArkTS lifecycle owner with controlled native futures.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const ts = require(process.argv[2] || "typescript");
const source = fs.readFileSync(path.join(__dirname, "../src/main/ets/player_session.ets"), "utf8");
const result = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true,
});
assert.equal(
  (result.diagnostics || []).filter((d) => d.category === ts.DiagnosticCategory.Error).length,
  0,
);
const context = { exports: {}, Promise };
vm.runInNewContext(result.outputText, context, { filename: "player_session.ets" });
const { PlayerSession } = context.exports;
const deferred = () => {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
};
const settle = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};
class FakePlayback {
  value = "idle";
  calls = [];
  released = 0;
  state() {
    return this.value;
  }
  observe(state, error) {
    this.changed = state;
    this.error = error;
  }
  emit(state) {
    this.value = state;
    this.changed(state);
  }
  source(fd) {
    this.calls.push(["source", fd]);
    this.emit("initialized");
  }
  prepare() {
    this.calls.push(["prepare"]);
    return Promise.resolve();
  }
  volume(value) {
    assert.ok(["prepared", "playing", "paused", "completed"].includes(this.value));
    this.calls.push(["volume", value]);
  }
  rewind() {
    this.calls.push(["seek", 0]);
  }
  play() {
    this.calls.push(["play"]);
    this.emit("playing");
    return this.playPromise || Promise.resolve();
  }
  release() {
    this.released++;
    this.value = "released";
    return this.releasePromise || Promise.resolve();
  }
}
const fixture = (factory) => {
  const source = {
    fd: 81,
    closed: 0,
    close() {
      this.closed++;
    },
  };
  const player = new FakePlayback();
  const errors = [];
  let creates = 0;
  const session = new PlayerSession(
    source,
    {
      create: () => {
        creates++;
        return factory ? factory(player) : Promise.resolve(player);
      },
    },
    (error) => errors.push(error),
  );
  return { source, player, errors, session, creates: () => creates };
};
(async () => {
  let cases = 0;
  {
    const f = fixture();
    f.session.update(0.2, true);
    f.session.begin(Promise.resolve());
    await settle();
    assert.deepEqual(f.player.calls, [["source", 81], ["prepare"]]);
    f.session.update(0.7, true);
    f.player.emit("prepared");
    await settle();
    assert.deepEqual(f.player.calls.slice(-3), [["volume", 0.7], ["seek", 0], ["play"]]);
    assert.equal(f.creates(), 1);
    await f.session.close();
    assert.equal(f.source.closed, 1);
    cases++;
  }
  {
    const f = fixture();
    f.session.begin(Promise.resolve());
    await settle();
    f.player.emit("prepared");
    f.session.update(0.3, true);
    await settle();
    f.session.update(0.5, true);
    await settle();
    assert.equal(f.player.calls.filter((c) => c[0] === "play").length, 1);
    assert.equal(f.player.calls.filter((c) => c[0] === "seek").length, 2);
    f.player.emit("completed");
    f.session.update(0.6, true);
    await settle();
    assert.equal(f.player.calls.filter((c) => c[0] === "play").length, 2);
    assert.equal(f.creates(), 1);
    await f.session.close();
    cases++;
  }
  {
    const creation = deferred();
    const f = fixture(() => creation.promise);
    f.session.update(0.4, true);
    f.session.begin(Promise.resolve());
    await settle();
    const closing = f.session.close();
    creation.resolve(f.player);
    await closing;
    assert.equal(f.player.released, 1);
    assert.deepEqual(f.player.calls, []);
    assert.equal(f.source.closed, 1);
    await f.session.close();
    assert.equal(f.source.closed, 1);
    cases++;
  }
  {
    const previous = deferred();
    const f = fixture();
    f.session.begin(previous.promise);
    const closing = f.session.close();
    previous.resolve();
    await closing;
    assert.equal(f.creates(), 0);
    assert.equal(f.source.closed, 1);
    cases++;
  }
  {
    const creation = deferred();
    const f = fixture(() => creation.promise);
    f.player.release = () => {
      f.player.released++;
      return Promise.reject(new Error("late release failed"));
    };
    f.session.begin(Promise.resolve());
    await settle();
    const closing = f.session.close();
    creation.resolve(f.player);
    await closing;
    assert.equal(f.player.released, 1);
    assert.equal(f.source.closed, 1);
    assert.match(f.errors[0], /late release failed/);
    cases++;
  }
  {
    const f = fixture();
    f.session.begin(Promise.resolve());
    await settle();
    await f.session.close();
    f.player.emit("prepared");
    f.player.error("late error");
    f.session.update(1, true);
    await settle();
    assert.equal(f.player.calls.filter((c) => c[0] === "play").length, 0);
    assert.deepEqual(f.errors, []);
    cases++;
  }
  {
    const release = deferred();
    const f = fixture();
    f.session.begin(Promise.resolve());
    await settle();
    f.player.releasePromise = release.promise;
    const closing = f.session.close();
    await settle();
    assert.equal(f.source.closed, 0);
    release.resolve();
    await closing;
    assert.equal(f.source.closed, 1);
    cases++;
  }
  {
    const f = fixture(() => Promise.reject(new Error("creation failed")));
    f.session.begin(Promise.resolve());
    await settle();
    assert.match(f.errors[0], /creation failed/);
    assert.equal(f.source.closed, 1);
    await f.session.close();
    assert.equal(f.source.closed, 1);
    cases++;
  }
  {
    const playing = deferred();
    const f = fixture();
    f.session.begin(Promise.resolve());
    await settle();
    f.player.playPromise = playing.promise;
    f.player.emit("prepared");
    f.session.update(0.1, true);
    f.session.update(0.9, true);
    f.session.update(0.4, true);
    await settle();
    assert.equal(f.player.calls.filter((c) => c[0] === "seek").length, 1);
    playing.resolve();
    await settle();
    assert.deepEqual(f.player.calls.slice(-2), [
      ["volume", 0.4],
      ["seek", 0],
    ]);
    assert.equal(f.player.calls.filter((c) => c[0] === "seek").length, 2);
    await f.session.close();
    cases++;
  }
  {
    const f = fixture();
    f.session.begin(Promise.resolve());
    await settle();
    f.player.emit("error");
    f.player.error("decoder failed");
    f.session.update(0.5, true);
    await settle();
    assert.deepEqual(f.errors, ["decoder failed"]);
    assert.equal(f.creates(), 1);
    assert.equal(f.player.calls.filter((c) => c[0] === "play").length, 0);
    assert.equal(f.player.released, 1);
    assert.equal(f.source.closed, 1);
    await f.session.close();
    cases++;
  }
  console.log(JSON.stringify({ all_passed: true, lifecycle_cases: cases }));
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
