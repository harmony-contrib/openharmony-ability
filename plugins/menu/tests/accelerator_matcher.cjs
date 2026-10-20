// Run the actual ArkTS matcher's TypeScript subset on Node. Supply the local
// DevEco TypeScript compiler as argv[2]; no network or generated matcher copy.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const ts = require(process.argv[2] || "typescript");
const source = fs.readFileSync(
  path.join(__dirname, "../src/main/ets/accelerator_matcher.ets"),
  "utf8",
);
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true,
});
assert.equal(
  (compiled.diagnostics || []).filter((d) => d.category === ts.DiagnosticCategory.Error).length,
  0,
);
const context = {
  exports: {},
  KeyType: { Down: 0, Up: 1 },
  require: (name) => {
    assert.equal(name, "@kit.InputKit");
    return {
      KeyCode: {
        KEYCODE_A: 2017,
        KEYCODE_Z: 2042,
        KEYCODE_0: 2000,
        KEYCODE_9: 2009,
        KEYCODE_F1: 2090,
        KEYCODE_F12: 2101,
        KEYCODE_DPAD_RIGHT: 2015,
      },
    };
  },
};
vm.runInNewContext(compiled.outputText, context, { filename: "accelerator_matcher.ets" });
const { AcceleratorMatcher } = context.exports;
const key = (code, modifiers = []) => ({
  type: 0,
  keyCode: code,
  keyText: "",
  getModifierKeyState: (names) => names.some((n) => modifiers.includes(n)),
});
const native = { id: "native", type: "item", accelerator: "Ctrl+Shift+right" };
const owned = {
  id: "renderer",
  type: "item",
  accelerator: "Ctrl+Shift+Super+right",
  acceleratorDisplayOnly: true,
};
let count = 0;
function test(name, body) {
  body();
  ++count;
  console.log(name + " passed");
}
test("legacy native accelerators still match and preserve modifier identity", () => {
  const matcher = new AcceleratorMatcher();
  matcher.buildFromItems([native, { ...owned, acceleratorDisplayOnly: false }]);
  assert(matcher.matches(key(2015, ["Ctrl", "Shift"])));
  assert.equal(matcher.getMatchedItem().id, "native");
  matcher.trackModifiers(key(2076));
  assert(matcher.matches(key(2015, ["Ctrl", "Shift"])));
  assert.equal(matcher.getMatchedItem().id, "renderer");
  matcher.resetModifiers();
  assert(matcher.matches(key(2015, ["Ctrl", "Shift"])));
  assert.equal(matcher.getMatchedItem().id, "native");
});
test("renderer chord is displayed but cannot steal the GPUI event", () => {
  const matcher = new AcceleratorMatcher();
  matcher.buildFromItems([native, owned]);
  matcher.trackModifiers(key(2076));
  assert.equal(matcher.matches(key(2015, ["Ctrl", "Shift"])), false);
  assert.equal(matcher.getMatchedItem(), null);
  assert.equal(owned.accelerator, "Ctrl+Shift+Super+right");
  matcher.resetModifiers();
  assert(matcher.matches(key(2015, ["Ctrl", "Shift"])));
  assert.equal(matcher.getMatchedItem().id, "native");
});
test("nested renderer labels do not disable ordinary native descendants", () => {
  const matcher = new AcceleratorMatcher();
  matcher.buildFromItems([
    { id: "parent", type: "submenu", acceleratorDisplayOnly: true, submenuItems: [owned, native] },
  ]);
  assert(matcher.matches(key(2015, ["Ctrl", "Shift"])));
  assert.equal(matcher.getMatchedItem().id, "native");
  matcher.trackModifiers(key(2076));
  assert.equal(matcher.matches(key(2015, ["Ctrl", "Shift"])), false);
});
test("replacing native matching with renderer ownership clears stale chords", () => {
  const matcher = new AcceleratorMatcher();
  matcher.trackModifiers(key(2076));
  matcher.buildFromItems([{ ...owned, acceleratorDisplayOnly: false }]);
  assert(matcher.matches(key(2015, ["Ctrl", "Shift"])));
  matcher.buildFromItems([owned]);
  assert.equal(matcher.matches(key(2015, ["Ctrl", "Shift"])), false);
  matcher.buildFromItems([{ ...native, enabled: false }]);
  matcher.resetModifiers();
  assert.equal(matcher.matches(key(2015, ["Ctrl", "Shift"])), false);
});
console.log(
  JSON.stringify({
    passed: count,
    scope:
      "Actual ArkTS matcher; renderer ownership, native default/false, nested items, replacement and independent Ctrl/Super",
  }),
);
