// Exercise the actual keyboard policy and suppression shim with a minimal DOM.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const ts = require(process.env.ABILITY_TYPESCRIPT || "typescript");
function load(relative, imports) {
  const output = ts.transpileModule(fs.readFileSync(path.join(__dirname, "..", relative), "utf8"), {
    fileName: relative.replace(/\.ets$/, ".ts"),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    reportDiagnostics: true,
  });
  assert.equal(output.diagnostics.length, 0);
  const mod = { exports: {} };
  new Function("require", "module", "exports", output.outputText)(
    (name) => {
      assert.ok(Object.hasOwn(imports, name), name);
      return imports[name];
    },
    mod,
    mod.exports,
  );
  return mod.exports;
}
const synthesis = load("native_ability/src/main/ets/helper/key_synthesis.ets", {
  "@kit.PerformanceAnalysisKit": { hilog: {} },
  "./constants": { DOMAIN: 0 },
});
const policy = load("plugins/webview/src/main/ets/WebviewKeyboardPolicy.ets", {
  "@ohos-rs/ability": synthesis,
});
const { usesLegacyWebviewKeyboard, webviewKeyboardScripts } = policy;
function document(scripts) {
  const callbacks = {};
  const window = {
    addEventListener(type, callback) {
      (callbacks[type] ??= []).push(callback);
    },
  };
  const context = { window };
  vm.createContext(context);
  for (const item of scripts) vm.runInContext(item.script, context);
  return {
    window,
    dispatch(type, synthetic = false) {
      let stopped = false;
      const event = {
        __ohosSynthetic: synthetic,
        stopImmediatePropagation() {
          stopped = true;
        },
      };
      for (const callback of callbacks[type] ?? []) {
        callback(event);
        if (stopped) break;
      }
      return !stopped;
    },
  };
}
test("custom host native mode preserves actual keydown and keyup across main/subwindows", () => {
  for (const windowId of [0, 1, 99]) {
    const scripts = [{ script: "window.applicationLoaded = true;", scriptRules: ["*"] }];
    assert.equal(usesLegacyWebviewKeyboard(true, null, windowId), false);
    const page = document(
      webviewKeyboardScripts(scripts, usesLegacyWebviewKeyboard(true, null, windowId)),
    );
    assert.equal(page.window.applicationLoaded, true);
    assert.equal(page.dispatch("keydown"), true);
    assert.equal(page.dispatch("keyup"), true);
    assert.equal(page.window.__ohosKeySynthesis, undefined);
  }
});
test("legacy main window retains its paired suppression behavior and custom URL rules", () => {
  const input = [
    { script: "window.first=true;", scriptRules: ["app://*", "https://*"] },
    { script: "window.second=true;", scriptRules: ["app://*"] },
  ];
  const scripts = webviewKeyboardScripts(input, usesLegacyWebviewKeyboard(false, null, 0));
  assert.equal(input.length, 2);
  assert.equal(scripts.length, 3);
  assert.deepEqual(scripts[2].scriptRules, ["app://*", "https://*"]);
  const page = document(scripts);
  assert.equal(page.window.first && page.window.second, true);
  assert.equal(page.dispatch("keydown"), false);
  assert.equal(page.dispatch("keyup"), false);
  assert.equal(page.dispatch("keydown", true), true);
  assert.equal(page.dispatch("keyup", true), true);
});
test("native attachments/subwindows retain native events and legacy empty rules match all", () => {
  for (const args of [
    [false, 7, 0],
    [false, null, 1],
  ]) {
    assert.equal(usesLegacyWebviewKeyboard(...args), false);
    const page = document(webviewKeyboardScripts([], usesLegacyWebviewKeyboard(...args)));
    assert.equal(page.dispatch("keydown"), true);
  }
  assert.deepEqual(webviewKeyboardScripts([], true)[0].scriptRules, ["*"]);
});
test("replacement document scripts retain native mode without injecting suppression", () => {
  const initial = [{ script: "window.version=1;", scriptRules: ["*"] }];
  const next = [{ script: "window.version=2;", scriptRules: ["https://*"] }];
  for (const scripts of [initial, next, []]) {
    const page = document(
      webviewKeyboardScripts(scripts, usesLegacyWebviewKeyboard(true, null, 0)),
    );
    assert.equal(page.dispatch("keydown"), true);
    assert.equal(page.dispatch("keyup"), true);
  }
  assert.equal(document(webviewKeyboardScripts(next, false)).window.version, 2);
});
test("key forwarding opt-in automatically disables legacy suppression shim", () => {
  assert.equal(usesLegacyWebviewKeyboard(false, null, 0, true), false);
  assert.equal(usesLegacyWebviewKeyboard(false, null, 0, false), true);
  const forwarding = load("plugins/webview/src/main/ets/WebviewKeyForwarding.ets", {});
  assert.equal(forwarding.shouldForwardWebviewKeys(false, false), false);
  assert.equal(forwarding.shouldForwardWebviewKeys(true, false), true);
  assert.equal(forwarding.shouldForwardWebviewKeys(false, true), true);
  assert.equal(forwarding.shouldForwardWebviewKeys(undefined, undefined), false);
});
