import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import test from "node:test";
// Keep actual production ownership classes; replace only SDK object effects.
const source = await readFile(new URL("../src/main/ets/NativeViews.ets", import.meta.url), "utf8");
const classes = source.slice(source.indexOf("class ViewEntry"));
const prefix = `const quarantinedViews = []; class NodeContent {} class BuilderNode { dispose() {} }
class NativeMenuCleanup { async settled() {} }`;
const { ViewEntry, NativeViews } = await import(
  `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(prefix + classes + "\nexport { ViewEntry }; ")).toString("base64")}`
);
function entry(accepted, calls) {
  const context = {
    getUIContext: () => ({}),
    invokeNativeSync: () => {
      calls.push("detach");
      return { accepted };
    },
  };
  return new ViewEntry({ id: "wrapper", targetId: 1 }, context, {});
}
test("rejected retirement never returns a successful batch acknowledgement", () => {
  const calls = [];
  const owner = entry(false, calls);
  const views = new NativeViews();
  views.entries.set("wrapper", owner);
  globalThis.expectBridgeRequestType = () => {};
  assert.throws(
    () => views.apply({ value: { remove: ["wrapper"], updates: [] } }, {}),
    /retirement/,
  );
  assert.throws(() => owner.dispose(), /retirement/);
  assert.deepEqual(calls, ["detach"]);
});
test("teardown visits all entries after a rejected detach and does not repeat success", () => {
  const first = [],
    second = [];
  const views = new NativeViews();
  const good = entry(true, second);
  views.entries.set("failed", entry(false, first));
  views.entries.set("good", good);
  assert.throws(() => views.dispose(), /retirement/);
  good.dispose();
  views.dispose();
  assert.deepEqual(first, ["detach"]);
  assert.deepEqual(second, ["detach"]);
});
