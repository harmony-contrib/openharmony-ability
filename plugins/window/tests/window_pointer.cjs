const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");
const sdk = process.env.OHOS_SDK_HOME;
if (!sdk) throw new Error("Set OHOS_SDK_HOME to the SDK directory containing ets/.");
const ts = require(path.join(sdk, "ets/build-tools/ets-loader/node_modules/typescript"));
const source = fs.readFileSync(path.join(__dirname, "../src/main/ets/WindowPointer.ets"), "utf8");
const compiled = ts.transpileModule(source, {
  compilerOptions: {
    module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2022,
  },
  reportDiagnostics: true,
});
assert.equal(
  (compiled.diagnostics || []).filter((d) => d.category === ts.DiagnosticCategory.Error).length,
  0,
);
const request = {
  rgba: [255, 128, 0, 64, 0, 0, 0, 0],
  width: 2,
  height: 1,
  hotspotX: 1,
  hotspotY: 0,
};
const win = { getWindowProperties: () => ({ id: 71 }) };

function deferred() {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

function fixture(options = {}) {
  const calls = [];
  const warnings = [];
  const pixelMap = {
    async release() {
      calls.push("release");
      await options.releaseGate?.promise;
      if (options.releaseFailure) throw options.releaseFailure;
      calls.push("released");
    },
  };
  const pointer = {
    setPointerStyleSync(id, style) {
      calls.push(["style", id, style]);
      if (options.styleFailure) throw options.styleFailure;
    },
    async setCustomCursor(...args) {
      calls.push(["custom", ...args]);
      await options.nativeGate?.promise;
      if (options.nativeFailure) throw options.nativeFailure;
      calls.push("installed");
    },
  };
  const context = {
    exports: {},
    Uint8Array,
    console: { warn: (warning) => warnings.push(warning) },
    require(name) {
      if (name === "@ohos.multimodalInput.pointer") return { default: pointer };
      if (name === "@kit.ImageKit")
        return {
          image: {
            async createPixelMap(bytes, settings) {
              calls.push("create");
              assert.deepEqual([...new Uint8Array(bytes)], request.rgba);
              assert.equal(settings.size.width, request.width);
              assert.equal(settings.size.height, request.height);
              assert.equal(settings.pixelFormat, 1);
              assert.equal(settings.srcPixelFormat, 1);
              assert.equal(settings.alphaType, 2);
              assert.equal(settings.editable, false);
              await options.createGate?.promise;
              if (options.createFailure) throw options.createFailure;
              return pixelMap;
            },
            PixelMapFormat: { RGBA_8888: 1 },
            AlphaType: { UNPREMUL: 2 },
          },
        };
      throw new Error(`Unexpected import ${name}`);
    },
  };
  vm.runInNewContext(compiled.outputText, context);
  return { ...context.exports, calls, warnings, pixelMap };
}

const flush = () => new Promise(setImmediate);

test("cursor styles use the resolved native ID and synchronous SDK setter", () => {
  const { WindowPointer, calls } = fixture();
  WindowPointer.setStyle(win, 5);
  assert.deepEqual(calls, [["style", 71, 5]]);
});

test("cursor styles propagate the original synchronous SDK error", () => {
  const failure = new Error("native style rejected");
  const { WindowPointer } = fixture({ styleFailure: failure });
  assert.throws(
    () => WindowPointer.setStyle(win, 5),
    (error) => error === failure,
  );
});

test("fixed-size custom cursors preserve RGBA pixels, hotspot and native window", async () => {
  const { WindowPointer, calls, pixelMap } = fixture();
  let checked = 0;
  await WindowPointer.setCustom(win, request, () => {
    checked++;
  });
  assert.deepEqual(calls, [
    "create",
    ["custom", 71, pixelMap, 1, 0],
    "installed",
    "release",
    "released",
  ]);
  assert.equal(checked, 3);
});

test("custom cursor acknowledgements wait for native installation and PixelMap release", async () => {
  const nativeGate = deferred();
  const releaseGate = deferred();
  const { WindowPointer, calls } = fixture({ nativeGate, releaseGate });
  let settled = false;
  const result = WindowPointer.setCustom(win, request, () => {}).finally(() => {
    settled = true;
  });
  await flush();
  assert.equal(settled, false);
  assert.equal(calls.includes("release"), false);
  nativeGate.resolve();
  await flush();
  assert.equal(calls.at(-1), "release");
  assert.equal(settled, false);
  releaseGate.resolve();
  await result;
  assert.equal(calls.at(-1), "released");
  assert.equal(settled, true);
});

test("PixelMap allocation failures do not install or release nonexistent pixels", async () => {
  const failure = new Error("allocation failed");
  const { WindowPointer, calls } = fixture({ createFailure: failure });
  await assert.rejects(
    WindowPointer.setCustom(win, request, () => {}),
    (error) => error === failure,
  );
  assert.deepEqual(calls, ["create"]);
});

test("native cursor errors await cleanup and preserve the primary error when cleanup fails", async () => {
  for (const releaseFailure of [undefined, new Error("release failed")]) {
    const failure = new Error("native rejected cursor");
    const releaseGate = deferred();
    const { WindowPointer, calls, warnings } = fixture({
      nativeFailure: failure,
      releaseFailure,
      releaseGate,
    });
    let settled = false;
    const result = WindowPointer.setCustom(win, request, () => {});
    result.then(
      () => {
        settled = true;
      },
      () => {
        settled = true;
      },
    );
    await flush();
    assert.equal(calls.at(-1), "release");
    assert.equal(settled, false);
    releaseGate.resolve();
    await assert.rejects(result, (error) => error === failure);
    assert.equal(calls.filter((call) => call === "release").length, 1);
    assert.equal(warnings.length, releaseFailure ? 1 : 0);
  }
});

test("cleanup failures after successful installation are not acknowledged", async () => {
  const failure = new Error("release failed");
  const { WindowPointer, calls } = fixture({ releaseFailure: failure });
  await assert.rejects(
    WindowPointer.setCustom(win, request, () => {}),
    (error) => error === failure,
  );
  assert.equal(calls.filter((call) => call === "release").length, 1);
});

test("window lookup failures still release the allocated PixelMap", async () => {
  const failure = new Error("window destroyed");
  const { WindowPointer, calls } = fixture();
  const destroyed = {
    getWindowProperties() {
      throw failure;
    },
  };
  await assert.rejects(
    WindowPointer.setCustom(destroyed, request, () => {}),
    (error) => error === failure,
  );
  assert.deepEqual(calls, ["create", "release", "released"]);
});

for (const stage of ["create", "native", "release"]) {
  test(`cancellation during ${stage} rejects after releasing owned pixels exactly once`, async () => {
    const gate = deferred();
    const failure = new Error("call no longer active");
    const { WindowPointer, calls } = fixture({
      createGate: stage === "create" ? gate : undefined,
      nativeGate: stage === "native" ? gate : undefined,
      releaseGate: stage === "release" ? gate : undefined,
      releaseFailure: stage === "native" ? new Error("cleanup also failed") : undefined,
    });
    let active = true;
    const result = WindowPointer.setCustom(win, request, () => {
      if (!active) throw failure;
    });
    await flush();
    active = false;
    gate.resolve();
    await assert.rejects(result, (error) => error === failure);
    assert.equal(calls.filter((call) => call === "release").length, 1);
    assert.equal(
      calls.some((call) => Array.isArray(call) && call[0] === "custom"),
      stage !== "create",
    );
  });
}
