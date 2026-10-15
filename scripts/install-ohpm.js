const { spawnSync } = require("node:child_process");
const { existsSync, readdirSync } = require("node:fs");
const { join, resolve } = require("node:path");

const repoRoot = resolve(__dirname, "..");
const command = process.platform === "win32" ? "ohpm-rs.exe" : "ohpm-rs";
const packages = [
  join(repoRoot, "native_ability"),
  ...readdirSync(join(repoRoot, "plugins"))
    .sort()
    .map((name) => join(repoRoot, "plugins", name)),
  join(repoRoot, "demo"),
];

for (const packageDir of packages) {
  if (!existsSync(join(packageDir, "oh-package.json5"))) continue;
  const result = spawnSync(command, ["install", "--all", "--prefix", packageDir], {
    cwd: repoRoot,
    stdio: "inherit",
  });
  if (result.error) {
    console.error(result.error.message);
    process.exit(1);
  }
  if (result.status !== 0) process.exit(result.status ?? 1);
}
