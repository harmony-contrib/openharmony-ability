// Production pointer adapter with controlled platform futures.
const assert = require("node:assert/strict");
const fs = require("node:fs"),
  path = require("node:path"),
  vm = require("node:vm");
const ts = require(process.argv[2] || "typescript");
const source = fs.readFileSync(path.join(__dirname, "../src/main/ets/WindowPointer.ets"), "utf8");
const calls = [];
let failure,
  releaseFailure,
  completed = false,
  proceed;
const map = {
  release: async () => {
    calls.push("release");
    if (releaseFailure) throw releaseFailure;
  },
};
const pointer = {
  getPointerStyleSync: (id) => {
    assert.equal(id, 71);
    return -5;
  },
  setPointerStyleSync: () => {
    if (failure) throw failure;
  },
  setCustomCursor: async (...args) => {
    calls.push(args);
    if (failure) throw failure;
    if (proceed)
      await new Promise((resolve) => {
        proceed = resolve;
      });
  },
};
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
const context = {
  exports: {},
  Uint8Array,
  require: (name) => {
    if (name === "@ohos.multimodalInput.pointer") return { default: pointer };
    if (name === "@kit.ImageKit")
      return {
        image: {
          createPixelMap: async () => map,
          PixelMapFormat: { RGBA_8888: 1 },
          AlphaType: { UNPREMUL: 1 },
        },
      };
    throw new Error(name);
  },
};
vm.runInNewContext(compiled.outputText, context);
const { WindowPointer } = context.exports;
const win = { getWindowProperties: () => ({ id: 71 }) };
const request = { rgba: [0, 0, 0, 0], width: 1, height: 1, hotspotX: 0, hotspotY: 0 };
(async () => {
  assert.equal(WindowPointer.getStyle(win), -5);
  await WindowPointer.setCustom(win, request, true, () => {});
  assert.equal(calls[0][0], 71);
  assert.equal(calls[0][2].followSystem, true);
  assert.equal(calls[1], "release");
  calls.length = 0;
  await WindowPointer.setCustom(win, request, false, () => {});
  assert.equal(calls[0].length, 4);
  assert.equal(calls[1], "release");
  ((failure = new Error("native")), (releaseFailure = new Error("release")));
  await assert.rejects(
    WindowPointer.setCustom(win, request, true, () => {}),
    (error) => error === failure,
  );
  assert.throws(
    () => WindowPointer.setStyle(win, 1),
    (error) => error === failure,
  );
  failure = undefined;
  releaseFailure = undefined;
  proceed = true;
  const pending = WindowPointer.setCustom(win, request, true, () => {}).then(() => {
    completed = true;
  });
  await new Promise(setImmediate);
  assert.equal(completed, false);
  proceed();
  await pending;
  await assert.rejects(
    WindowPointer.setCustom(win, request, true, () => {
      throw new Error("cancelled");
    }),
    /cancelled/,
  );
  console.log("7 pointer completion/ownership cases passed");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
