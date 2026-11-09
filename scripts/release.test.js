const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

// Exercise the real release scripts and Git branches against a local bare remote.
// Only OHPM, formatting and GitHub calls are replaced, so no packages or PRs are published.
const mockCli = `#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const args = process.argv.slice(2);
const stateFile = process.env.HAR_RELEASE_TEST_STATE;
const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
const command = path.basename(process.argv[1]);
state.calls.push({ command, args });
function value(flag) { return args[args.indexOf(flag) + 1]; }
function output(value) { console.log(JSON.stringify(value)); }
if (command === "ohpm-rs") {
  if (args[0] === "version") {
    const filter = value("--filter").split(",");
    for (const dir of ["native_ability", ...fs.readdirSync("plugins").map(name => "plugins/" + name)]) {
      const file = path.join(dir, "oh-package.json5");
      const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
      if (filter.includes(manifest.name)) {
        manifest.version = args[1];
        fs.writeFileSync(file, JSON.stringify(manifest, null, 2) + "\\n");
      }
    }
  } else if (args[0] === "install" && args.includes("--lockfile-only")) {
    const dir = value("--prefix");
    const manifest = JSON.parse(fs.readFileSync(path.join(dir, "oh-package.json5"), "utf8"));
    fs.writeFileSync(path.join(dir, "oh-package-lock.json5"), manifest.version + "\\n");
  } else {
    throw new Error("Unexpected OHPM call: " + args.join(" "));
  }
} else if (command === "gh") {
  if (args[1] === "list") {
    output(state.prs.filter(pr => pr.open && pr.head === value("--head") && pr.base === value("--base")));
  } else if (args[1] === "create") {
    const pr = {
      number: state.prs.length + 1,
      open: true,
      head: value("--head"),
      base: value("--base"),
      title: value("--title"),
      body: fs.readFileSync(value("--body-file"), "utf8")
    };
    state.prs.push(pr);
    output(pr);
  } else if (args[1] === "edit") {
    state.prs.find(pr => pr.number === Number(args[2])).body = fs.readFileSync(value("--body-file"), "utf8");
  } else if (args[1] === "view") {
    console.log(state.prs.find(pr => pr.number === Number(args[2])).body);
  } else {
    throw new Error("Unexpected GitHub call: " + args.join(" "));
  }
} else if (command !== "pnpm" || args.join(" ") !== "exec oxk format **/*.{ets,js,ts,json5} -t=10") {
  throw new Error("Unexpected command: " + command + " " + args.join(" "));
}
fs.writeFileSync(stateFile, JSON.stringify(state));
`;

function fixture(t, harChanged = true) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "har-release-test-"));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));
  const repo = path.join(tmpDir, "repo");
  const bin = path.join(tmpDir, "bin");
  fs.mkdirSync(repo);
  fs.mkdirSync(bin);
  const stateFile = path.join(tmpDir, "github.json");
  fs.writeFileSync(stateFile, JSON.stringify({ prs: [], calls: [] }));
  for (const command of ["ohpm-rs", "pnpm", "gh"]) {
    fs.writeFileSync(path.join(bin, command), mockCli, { mode: 0o755 });
  }
  const env = {
    ...process.env,
    PATH: `${bin}${path.delimiter}${process.env.PATH}`,
    GITHUB_REF_NAME: "main",
    PR_JSON: "{}",
    HAR_RELEASE_TEST_STATE: stateFile,
  };
  function run(command, args, overrides = {}) {
    return execFileSync(command, args, {
      cwd: repo,
      env: { ...env, ...overrides },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  }
  const git = (...args) => run("git", args);
  function write(file, content) {
    fs.mkdirSync(path.dirname(path.join(repo, file)), { recursive: true });
    fs.writeFileSync(path.join(repo, file), content);
  }
  const read = (file) => fs.readFileSync(path.join(repo, file), "utf8");
  const commit = (message) => {
    git("add", "-A");
    git("commit", "-m", message);
  };
  git("init", "--initial-branch=main");
  git("config", "user.name", "Release test");
  git("config", "user.email", "release-test@example.com");
  git("config", "commit.gpgsign", "false");
  git("config", "core.hooksPath", path.join(tmpDir, "hooks"));
  for (const name of ["sync-release.js", "create-har-release-pr.js", "install-ohpm.js"]) {
    write(`scripts/${name}`, fs.readFileSync(path.join(__dirname, name), "utf8"));
  }
  const packages = [
    { dir: "native_ability", crate: "ability", name: "ability", dependencies: {} },
    { dir: "plugins/files", crate: "plugin-files", name: "ability-plugin-files", dependencies: {} },
    {
      dir: "plugins/consumer",
      crate: "plugin-consumer",
      name: "ability-plugin-consumer",
      dependencies: { "@ohos-rs/ability-plugin-files": "workspace:*" },
    },
  ];
  for (const pkg of packages) {
    write(
      `${pkg.dir}/oh-package.json5`,
      JSON.stringify(
        { name: `@ohos-rs/${pkg.name}`, version: "1.0.0-beta.5", dependencies: pkg.dependencies },
        null,
        2,
      ) + "\n",
    );
    write(`${pkg.dir}/oh-package-lock.json5`, "1.0.0-beta.5\n");
    write(`${pkg.dir}/BuildProfile.ets`, 'export const HAR_VERSION = "1.0.0-beta.5";\n');
    write(`${pkg.dir}/CHANGELOG.md`, "# Changelog\n\n## [Unreleased]\n");
    write(
      `crates/${pkg.crate}/Cargo.toml`,
      `[package]\nname = "openharmony-${pkg.name}"\nversion = "1.0.0-beta.5"\n`,
    );
  }
  write("plugins/files/src/FilesPlugin.ets", "// original picker\n");
  commit("chore: release");
  for (const pkg of packages) {
    git("tag", `openharmony-${pkg.name}-v1.0.0-beta.5`);
  }
  if (harChanged) {
    write("plugins/files/src/FilesPlugin.ets", "// atomic save picker\n");
    commit("fix(files): support atomic saves");
  }
  git("init", "--bare", path.join(tmpDir, "remote.git"));
  git("remote", "add", "origin", path.join(tmpDir, "remote.git"));
  git("push", "--set-upstream", "origin", "main");
  return {
    git,
    write,
    read,
    commit,
    run: () => run(process.execPath, ["scripts/create-har-release-pr.js"]),
    sync: (args = [], overrides = {}) =>
      run(process.execPath, ["scripts/sync-release.js", ...args], overrides),
    state: () => JSON.parse(fs.readFileSync(stateFile, "utf8")),
    setState: (state) => fs.writeFileSync(stateFile, JSON.stringify(state)),
    version: (dir) => JSON.parse(read(`${dir}/oh-package.json5`)).version,
  };
}

test("HAR-only changes create a release PR with dependency bumps and release notes", (t) => {
  const f = fixture(t);
  f.run();
  const [pr] = f.state().prs;
  assert.equal(pr.head, "release-plz-har-main");
  assert.equal(pr.base, "main");
  assert.equal(pr.title, "chore: release");
  assert.match(pr.body, /@ohos-rs\/ability-plugin-files.*1\.0\.0-beta\.5 -> 1\.0\.0-beta\.6/);
  assert.match(pr.body, /fix\(files\): support atomic saves/);
  assert.match(pr.body, /## `@ohos-rs\/ability-plugin-consumer`/);
  assert.equal(f.version("plugins/files"), "1.0.0-beta.6");
  assert.equal(f.version("plugins/consumer"), "1.0.0-beta.6");
  assert.equal(f.version("native_ability"), "1.0.0-beta.5");
  assert.equal(f.read("plugins/files/oh-package-lock.json5"), "1.0.0-beta.6\n");
  assert.match(f.read("plugins/files/BuildProfile.ets"), /1\.0\.0-beta\.6/);
  assert.equal(f.git("diff", "main", "--", "crates"), "");
  assert.equal(f.git("status", "--porcelain"), "");
  assert.match(
    f.git("ls-remote", "--heads", "origin", pr.head),
    /refs\/heads\/release-plz-har-main/,
  );
});

test("reruns reuse the open HAR PR without incrementing its proposed versions", (t) => {
  const f = fixture(t);
  f.run();
  f.git("checkout", "main");
  f.run();
  const state = f.state();
  assert.equal(state.prs.length, 1);
  assert.equal(state.calls.filter((c) => c.command === "gh" && c.args[1] === "create").length, 1);
  assert.equal(state.calls.filter((c) => c.command === "gh" && c.args[1] === "edit").length, 1);
  assert.equal(f.version("plugins/files"), "1.0.0-beta.6");
  assert.equal(f.git("rev-list", "--count", "main..HEAD"), "1");
});

test("new HAR commits refresh the pending PR from main", (t) => {
  const f = fixture(t);
  f.run();
  f.git("checkout", "main");
  f.write("plugins/files/src/FilesPlugin.ets", "// atomic save with capability guards\n");
  f.commit("fix(files): guard picker capabilities");
  f.run();
  assert.equal(f.state().prs.length, 1);
  assert.equal(f.version("plugins/files"), "1.0.0-beta.6");
  assert.match(f.state().prs[0].body, /guard picker capabilities/);
  assert.match(f.read("plugins/files/src/FilesPlugin.ets"), /capability guards/);
  assert.equal(f.git("merge-base", "main", "HEAD"), f.git("rev-parse", "main"));
});

test("a push with no HAR changes leaves main clean and creates no PR", (t) => {
  const f = fixture(t, false);
  assert.match(f.run(), /No HAR packages require a release PR/);
  assert.equal(f.state().calls.length, 0);
  assert.equal(f.git("branch", "--show-current"), "main");
  assert.equal(f.git("status", "--porcelain"), "");
});

test("a merged HAR-only release does not create another release PR", (t) => {
  const f = fixture(t);
  f.run();
  f.git("checkout", "main");
  f.git("merge", "--squash", "release-plz-har-main");
  f.commit("chore: release (#1)");
  const state = f.state();
  state.prs[0].open = false;
  f.setState(state);
  f.write("README.md", "Release infrastructure documentation\n");
  f.commit("docs: explain releases");
  assert.match(f.run(), /No HAR packages require a release PR/);
  assert.deepEqual(f.state(), state);
  assert.equal(f.version("plugins/files"), "1.0.0-beta.6");
  assert.equal(f.git("branch", "--show-current"), "main");
});

test("HAR sync still augments an existing Rust release PR", (t) => {
  const f = fixture(t);
  f.git("checkout", "-b", "release-plz-rust");
  f.write(
    "crates/plugin-files/Cargo.toml",
    '[package]\nname = "openharmony-ability-plugin-files"\nversion = "1.0.0-beta.7"\n',
  );
  f.commit("chore: release");
  const state = f.state();
  state.prs.push({
    number: 1,
    body:
      "Rust package summary\n\n" +
      "<details><summary><i><b>Changelog</b></i></summary><p>\n\n</p></details>\n",
  });
  f.setState(state);
  f.sync([], { PR_JSON: '{"number":1,"head_branch":"release-plz-rust"}' });
  assert.equal(f.version("plugins/files"), "1.0.0-beta.7");
  assert.match(f.state().prs[0].body, /Rust package summary/);
  assert.match(f.state().prs[0].body, /@ohos-rs\/ability-plugin-files.*1\.0\.0-beta\.7/);
  assert.equal(f.state().prs.length, 1);
});
