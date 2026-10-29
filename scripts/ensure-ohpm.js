// Keep the installed ohpm-rs CLI aligned with the version this repository
// expects. `cargo install` refuses to overwrite a different version without
// --force, which would otherwise make `pnpm install` fail for anyone
// upgrading from an older pin.

const { spawnSync } = require("node:child_process");

const OHPM_CLI_VERSION = "0.5.0";
const command = process.platform === "win32" ? "ohpm-rs.exe" : "ohpm-rs";

const installed = spawnSync(command, ["--version"], { encoding: "utf8" });
if (installed.status === 0 && installed.stdout.includes(` ${OHPM_CLI_VERSION}`)) {
  process.exit(0);
}

const result = spawnSync(
  "cargo",
  ["install", "ohpm-cli", "--version", OHPM_CLI_VERSION, "--locked", "--force"],
  { stdio: "inherit" },
);
if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
process.exit(result.status ?? 1);
