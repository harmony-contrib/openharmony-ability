import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { discoverRepositoryTests, discoverTests } from "./run-tests.mjs";

test("discovers existing CommonJS regressions and nested ESM tests deterministically", (t) => {
  const directory = mkdtempSync(join(tmpdir(), "ability-node-tests-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  mkdirSync(join(directory, "nested"));
  const expected = [
    "legacy-checks.cjs",
    "nested/window-status-bar.test.mjs",
    "runtime-regressions.cjs",
    "session.spec.js",
  ];
  for (const file of [...expected, "install-ohpm.js", "run-tests.mjs", "notes.md"]) {
    writeFileSync(join(directory, file), "");
  }
  assert.deepEqual(
    discoverTests(directory),
    expected.map((file) => join(directory, file)),
  );
});

test("does not treat a directory with a test suffix as an executable test file", (t) => {
  const directory = mkdtempSync(join(tmpdir(), "ability-node-tests-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  mkdirSync(join(directory, "not-a-file.test.mjs"));
  assert.deepEqual(discoverTests(directory), []);
});

test("includes plugin and core test directories without executing dependency helpers", (t) => {
  const directory = mkdtempSync(join(tmpdir(), "ability-node-tests-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const files = [
    "scripts/runtime-regressions.cjs",
    "native_ability/tests/lifecycle.test.mjs",
    "plugins/window/tests/window_pointer.cjs",
    "plugins/window/oh_modules/dependency/unused.cjs",
    "scripts/node_modules/dependency/unused.cjs",
  ];
  for (const file of files) {
    mkdirSync(join(directory, file, ".."), { recursive: true });
    writeFileSync(join(directory, file), "");
  }
  assert.deepEqual(
    discoverRepositoryTests(directory),
    files
      .slice(0, 3)
      .map((file) => join(directory, file))
      .sort(),
  );
});
