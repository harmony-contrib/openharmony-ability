const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const root = path.resolve(__dirname, "../../..");
const sdk = process.env.OHOS_SDK_HOME;
if (!sdk) throw new Error("Set OHOS_SDK_HOME to the SDK directory containing ets/.");
const ts = require(path.join(sdk, "ets/build-tools/ets-loader/node_modules/typescript"));

function loadRuntime() {
  const cache = new Map();
  function load(relative) {
    const filename = path.resolve(root, relative);
    if (cache.has(filename)) return cache.get(filename);
    const exports = {};
    cache.set(filename, exports);
    const { outputText, diagnostics } = ts.transpileModule(fs.readFileSync(filename, "utf8"), {
      fileName: filename.replace(/\.ets$/, ".ts"),
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
      reportDiagnostics: true,
    });
    assert.equal(diagnostics?.length ?? 0, 0, filename);
    vm.runInNewContext(
      outputText,
      {
        exports,
        console,
        setTimeout,
        clearTimeout,
        Uint8Array,
        ArrayBuffer,
        require(specifier) {
          if (specifier === "@ohos-rs/ability") {
            return load("native_ability/src/main/ets/ability/type.ets");
          }
          if (specifier === "../window/WindowManager") return {};
          if (
            !filename.endsWith("ClipboardPlugin.ets") &&
            ["@ohos.arkui.node", "@ohos.window"].includes(specifier)
          ) {
            return {};
          }
          if (specifier.startsWith(".")) {
            return load(
              path.relative(root, path.resolve(path.dirname(filename), `${specifier}.ets`)),
            );
          }
          throw new Error(`Unexpected platform import: ${specifier}`);
        },
      },
      { filename },
    );
    return exports;
  }
  return load;
}

test("real clipboard HAR registers with BridgeHost but cannot transport clipboard data", async () => {
  const load = loadRuntime();
  const { ClipboardPlugin } = load("plugins/clipboard/src/main/ets/ClipboardPlugin.ets");
  const { BridgeHostRegistry } = load("native_ability/src/main/ets/bridge/BridgeHost.ets");
  const plugin = new ClipboardPlugin();
  assert.equal(plugin.id, "ohos.clipboard");
  assert.equal(plugin.execution, "async");
  assert.deepEqual(Array.from(plugin.requires), ["ability"]);
  const moduleName = "native-clipboard-test";
  const session = BridgeHostRegistry.prepare([moduleName], {}, [{ create: () => plugin }]);
  try {
    BridgeHostRegistry.configurePlugins(session, moduleName, [
      {
        id: plugin.id,
        execution: plugin.execution,
        requires: plugin.requires,
      },
    ]);
    await BridgeHostRegistry.activateAbility(session, moduleName, {
      kind: "ability-create",
      payload: {},
    });
    for (const action of [
      "read-mime",
      "write-mime",
      "read-records",
      "write-records",
      "read-text",
      "write-text",
      "read-authorized-records",
      "write-image",
      "clear",
    ]) {
      await assert.rejects(
        BridgeHostRegistry.invokeAsync(
          session,
          moduleName,
          plugin.id,
          action,
          "std.bool",
          "std.bool",
          false,
          1000,
        ),
        /use the native Rust clipboard facade/,
      );
    }
  } finally {
    await BridgeHostRegistry.dispose(session);
    await BridgeHostRegistry.dispose(session);
  }
  await assert.rejects(
    plugin.invokeAsync(
      "read-mime",
      { typeName: "std.bool", value: false },
      { isActive: () => false },
    ),
    /no longer active/,
  );
});

test("production Rust MIME policy executes on host without native FFI or N-API stubs", () => {
  const directory = path.resolve(
    process.env.CARGO_TARGET_DIR || path.join(root, "target"),
    "clipboard-policy-tests",
  );
  fs.mkdirSync(directory, { recursive: true });
  const binary = path.join(directory, `clipboard-policy-${process.pid}`);
  const run = (command, args) => {
    const result = spawnSync(command, args, { cwd: root, encoding: "utf8" });
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    return result.stdout;
  };
  try {
    run("rustc", ["--edition=2021", "--test", "crates/plugin-clipboard/src/mime.rs", "-o", binary]);
    assert.match(run(binary, []), /test result: ok/);
  } finally {
    fs.rmSync(binary, { force: true });
  }
});
