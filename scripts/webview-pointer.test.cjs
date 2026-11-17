// Actual ArkTS input observer, with SDK event objects represented by host doubles.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const ts = require(process.env.ABILITY_TYPESCRIPT || "typescript");
const filename = path.join(__dirname, "../plugins/webview/src/main/ets/WebviewPointerEvents.ets");
const output = ts.transpileModule(fs.readFileSync(filename, "utf8"), {
  fileName: "WebviewPointerEvents.ts",
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  reportDiagnostics: true,
});
assert.equal(output.diagnostics.length, 0);
const loaded = { exports: {} };
const MouseAction = { Press: 0, Release: 1, Move: 2 };
const MouseButton = { Left: 0, Right: 1, Middle: 2, Back: 3, Forward: 4, None: 5 };
const TouchType = { Down: 0, Up: 1, Move: 2, Cancel: 3 };
const SourceType = { Mouse: 1, TouchScreen: 2 };
new Function(
  "require",
  "module",
  "exports",
  "MouseAction",
  "MouseButton",
  "TouchType",
  "SourceType",
  output.outputText,
)(() => ({}), loaded, loaded.exports, MouseAction, MouseButton, TouchType, SourceType);
const { WebviewPointerEvents, parsePointerEvents } = loaded.exports;
function fixture() {
  const events = [];
  const live = { current: true };
  const observer = new WebviewPointerEvents(
    "child",
    "generation-2",
    () => live.current,
    (e) => events.push(e),
  );
  const mouse = {
    action: 0,
    button: 0,
    x: 1.25,
    y: -3.5,
    stopPropagation() {
      assert.fail("input was intercepted");
    },
    preventDefault() {
      assert.fail("browser default was prevented");
    },
    getModifierKeyState(keys) {
      return ["Shift", "Alt"].includes(keys[0]);
    },
  };
  return { events, live, observer, mouse };
}
test("named request validates type, id and enable flag", () => {
  const typeName = "ohos.webview.PointerEventsRequest";
  for (const value of [null, {}, { id: "", enabled: true }, { id: "x", enabled: 1 }]) {
    assert.throws(() => parsePointerEvents({ typeName, value }));
  }
  assert.throws(() => parsePointerEvents({ typeName: "other", value: { id: "x", enabled: true } }));
  assert.equal(parsePointerEvents({ typeName, value: { id: "x", enabled: false } }).enabled, false);
});
test("mouse buttons and fractional local coordinates are copied, without consuming input", () => {
  const { events, observer, mouse } = fixture();
  observer.enabled = true;
  for (let button = 0; button < 5; button++) observer.mouse({ ...mouse, button });
  assert.deepEqual(
    events.map((e) => e.button),
    [0, 1, 2, 3, 4],
  );
  assert.deepEqual(
    { ...events[0] },
    { id: "child", nativeTag: "generation-2", x: 1.25, y: -3.5, button: 0, modifiers: 5 },
  );
  mouse.x = 100;
  assert.equal(events[0].x, 1.25);
});
test("disabled, stale, release, move, unknown buttons and invalid coordinates emit nothing", () => {
  const { events, live, observer, mouse } = fixture();
  observer.mouse(mouse);
  observer.enabled = true;
  live.current = false;
  observer.mouse(mouse);
  live.current = true;
  for (const patch of [
    { action: 1 },
    { action: 2 },
    { button: 5 },
    { button: -1 },
    { x: NaN },
    { y: Infinity },
  ])
    observer.mouse({ ...mouse, ...patch });
  assert.equal(events.length, 0);
  observer.mouse(mouse);
  observer.enabled = false;
  observer.mouse(mouse);
  assert.equal(events.length, 1);
});
test("touch filters mouse duplicates and secondary contacts; reports first contact", () => {
  const { events, observer, mouse } = fixture();
  observer.enabled = true;
  const p = { id: 4, x: 5.5, y: 7.25 };
  const touch = { ...mouse, type: 0, source: 2, touches: [p], changedTouches: [p] };
  for (const patch of [
    { source: 1 },
    { type: 1 },
    { type: 2 },
    { type: 3 },
    { touches: [] },
    { touches: [p, { id: 5 }] },
    { changedTouches: [] },
    { changedTouches: [{ ...p, id: 5 }] },
  ])
    observer.touch({ ...touch, ...patch });
  assert.equal(events.length, 0);
  observer.touch(touch);
  assert.deepEqual(
    { ...events[0] },
    { id: "child", nativeTag: "generation-2", x: 5.5, y: 7.25, button: 0, modifiers: 5 },
  );
});
test("older/stylus events without modifier support remain deliverable", () => {
  const { events, observer, mouse } = fixture();
  observer.enabled = true;
  observer.mouse({ ...mouse, getModifierKeyState: undefined });
  observer.mouse({
    ...mouse,
    getModifierKeyState() {
      throw Error("stylus");
    },
  });
  assert.deepEqual(
    events.map((e) => e.modifiers),
    [0, 0],
  );
});
