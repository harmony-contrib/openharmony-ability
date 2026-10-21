import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import test from "node:test";
const source = await readFile(
  new URL("../src/main/ets/ControlledText.ets", import.meta.url),
  "utf8",
);
const { ControlledText } = await import(
  `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString("base64")}`
);
test("late controlled acknowledgements preserve newer native composition", () => {
  const value = new ControlledText("a", 0);
  value.change("ab");
  value.change("abc");
  value.update("AB", 1);
  assert.equal(value.text, "abc");
  assert.equal(value.count, 2);
  value.update("ABC", 2);
  assert.equal(value.text, "ABC");
  assert.equal(value.change("ABC"), false);
  assert.equal(value.count, 2);
});
test("native edit counts retain their wire u32 range", () => {
  const value = new ControlledText("old", 0xffffffff);
  assert.equal(value.change("new"), true);
  assert.equal(value.count, 0);
  value.update("stale", 0xffffffff);
  assert.equal(value.text, "new");
});
