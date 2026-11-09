const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const rootDir = path.resolve(__dirname, "..");
const baseBranch = process.env.GITHUB_REF_NAME || "main";
// release-plz recognizes this prefix when Rust changes later join the same PR.
const branch = `release-plz-har-${baseBranch}`;

function run(command, args, inherit = false) {
  return execFileSync(command, args, {
    cwd: rootDir,
    encoding: "utf8",
    stdio: inherit ? "inherit" : ["ignore", "pipe", "inherit"],
  })?.trim();
}

if (run("git", ["status", "--porcelain"])) {
  throw new Error("HAR release PR creation requires a clean working tree");
}
if (run("git", ["branch", "--show-current"]) !== baseBranch) {
  throw new Error(`HAR release PR creation must start on ${baseBranch}`);
}

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "har-release-pr-"));
const bodyFile = path.join(tmpDir, "body.md");
try {
  fs.writeFileSync(
    bodyFile,
    "This release updates the following HAR packages.\n\n" +
      "<details><summary><i><b>Changelog</b></i></summary><p>\n\n</p></details>\n",
  );
  // Always calculate from main, so reruns update the same proposed versions.
  run(process.execPath, ["scripts/sync-release.js", "--pr-body-file", bodyFile], true);
  if (!run("git", ["status", "--porcelain"])) {
    console.log("No HAR packages require a release PR.");
  } else {
    const prs = JSON.parse(
      run("gh", [
        "pr",
        "list",
        "--base",
        baseBranch,
        "--head",
        branch,
        "--state",
        "open",
        "--json",
        "number",
      ]),
    );
    const remoteRef = `refs/heads/${branch}`;
    const remoteSha = run("git", ["ls-remote", "--heads", "origin", remoteRef]).split("\t")[0];

    run("git", ["checkout", "-B", branch], true);
    run("git", ["config", "user.name", "github-actions[bot]"]);
    run("git", ["config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"]);
    run("git", ["add", "-A"]);
    run("git", ["commit", "-m", "chore: release"], true);
    run(
      "git",
      ["push", `--force-with-lease=${remoteRef}:${remoteSha}`, "origin", `HEAD:${remoteRef}`],
      true,
    );

    if (prs.length > 0) {
      run("gh", ["pr", "edit", String(prs[0].number), "--body-file", bodyFile], true);
    } else {
      run(
        "gh",
        [
          "pr",
          "create",
          "--base",
          baseBranch,
          "--head",
          branch,
          "--title",
          "chore: release",
          "--body-file",
          bodyFile,
        ],
        true,
      );
    }
  }
} finally {
  fs.rmSync(tmpDir, { recursive: true, force: true });
}
