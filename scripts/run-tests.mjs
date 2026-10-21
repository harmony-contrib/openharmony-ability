import { spawnSync } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export function discoverTests(directory) {
  return readdirSync(directory, { withFileTypes: true })
    .flatMap((entry) => {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        return ["node_modules", "oh_modules", "build", "dist"].includes(entry.name)
          ? []
          : discoverTests(path);
      }
      return entry.isFile() &&
        (entry.name.endsWith(".cjs") ||
          /(?:[.-](?:test|spec|regressions)|^test)\.(?:mjs|js)$/.test(entry.name))
        ? [path]
        : [];
    })
    .sort();
}

export function discoverRepositoryTests(root) {
  const directories = [
    join(root, "scripts"),
    join(root, "native_ability", "tests"),
    ...readdirSync(join(root, "plugins"), { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => join(root, "plugins", entry.name, "tests")),
  ];
  return directories.filter(existsSync).flatMap(discoverTests).sort();
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const tests = discoverRepositoryTests(root);
  if (tests.length === 0)
    throw new Error("No Node test files found in repository test directories.");
  const result = spawnSync(process.execPath, ["--experimental-vm-modules", "--test", ...tests], {
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  process.exit(result.status ?? 1);
}
