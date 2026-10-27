const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const rootDir = path.resolve(__dirname, "..");
const versionOnly = process.argv.includes("--version-only");
const dryRun = process.argv.includes("--dry-run");

// Historical unified release commit for 1.0.0-beta.3 before per-package release-plz tags.
const HISTORICAL_RELEASE_COMMITS = {
  "1.0.0-beta.3": "439b682ad664e7107143d5b800687f63df03f1b5",
};

function git(args, allowFailure = false) {
  try {
    return execFileSync("git", args, {
      cwd: rootDir,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch (error) {
    if (allowFailure) {
      return "";
    }
    throw error;
  }
}

function commitExists(rev) {
  if (!rev) {
    return false;
  }
  return git(["rev-parse", "--verify", "--quiet", `${rev}^{commit}`], true) !== "";
}

function fileExistsAtCommit(rev, relPath) {
  if (!commitExists(rev)) {
    return false;
  }
  try {
    execFileSync("git", ["cat-file", "-e", `${rev}:${relPath}`], {
      cwd: rootDir,
      stdio: "ignore",
    });
    return true;
  } catch {
    return false;
  }
}

function readHarManifest(harDir) {
  const manifestPath = path.join(rootDir, harDir, "oh-package.json5");
  const content = fs.readFileSync(manifestPath, "utf8");
  const nameMatch = content.match(/^  "name"\s*:\s*"([^"]+)"/m);
  const versionMatch = content.match(/^  "version"\s*:\s*"([^"]+)"/m);
  if (!nameMatch || !versionMatch) {
    throw new Error(`Failed to parse name/version from ${manifestPath}`);
  }
  return {
    name: nameMatch[1],
    version: versionMatch[1],
  };
}

function readCrateManifest(crateDir) {
  const manifestPath = path.join(rootDir, crateDir, "Cargo.toml");
  if (!fs.existsSync(manifestPath)) {
    return null;
  }
  const content = fs.readFileSync(manifestPath, "utf8");
  const nameMatch = content.match(/^name\s*=\s*"([^"]+)"/m);
  const versionMatch = content.match(/^version\s*=\s*"([^"]+)"/m);
  if (!nameMatch || !versionMatch) {
    return null;
  }
  return {
    name: nameMatch[1],
    version: versionMatch[1],
  };
}

function parseSemver(version) {
  const match = version.trim().match(/^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?/);
  if (!match) {
    return null;
  }
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    prerelease: match[4] ? match[4].split(".") : [],
  };
}

function compareSemver(a, b) {
  const va = parseSemver(a);
  const vb = parseSemver(b);
  if (!va || !vb) {
    return a.localeCompare(b);
  }
  if (va.major !== vb.major) return va.major - vb.major;
  if (va.minor !== vb.minor) return va.minor - vb.minor;
  if (va.patch !== vb.patch) return va.patch - vb.patch;
  if (va.prerelease.length === 0 && vb.prerelease.length === 0) return 0;
  if (va.prerelease.length === 0) return 1;
  if (vb.prerelease.length === 0) return -1;
  const len = Math.max(va.prerelease.length, vb.prerelease.length);
  for (let i = 0; i < len; i++) {
    const idA = va.prerelease[i];
    const idB = vb.prerelease[i];
    if (idA === undefined) return -1;
    if (idB === undefined) return 1;
    const numA = /^\d+$/.test(idA) ? Number(idA) : null;
    const numB = /^\d+$/.test(idB) ? Number(idB) : null;
    if (numA !== null && numB !== null) {
      if (numA !== numB) return numA - numB;
    } else if (numA !== null) {
      return -1;
    } else if (numB !== null) {
      return 1;
    } else if (idA !== idB) {
      return idA.localeCompare(idB);
    }
  }
  return 0;
}

function incrementVersion(version) {
  const parsed = parseSemver(version);
  if (!parsed) {
    throw new Error(`Invalid semantic version: ${version}`);
  }
  if (parsed.prerelease.length > 0) {
    const nextPre = [...parsed.prerelease];
    const last = nextPre[nextPre.length - 1];
    if (/^\d+$/.test(last)) {
      nextPre[nextPre.length - 1] = String(Number(last) + 1);
    } else {
      nextPre.push("0");
    }
    return `${parsed.major}.${parsed.minor}.${parsed.patch}-${nextPre.join(".")}`;
  }
  return `${parsed.major}.${parsed.minor}.${parsed.patch + 1}`;
}

function findHarReleaseBaseCommit(harDir, harName, harVersion, crateName) {
  const candidateTags = [
    `${harName}-v${harVersion}`,
    crateName ? `${crateName}-v${harVersion}` : "",
    `v${harVersion}`,
  ].filter(Boolean);

  for (const tag of candidateTags) {
    const rev = git(["rev-parse", "--verify", "--quiet", `refs/tags/${tag}^{commit}`], true);
    if (rev) {
      return rev;
    }
  }

  const historicalCommit = HISTORICAL_RELEASE_COMMITS[harVersion];
  if (historicalCommit && fileExistsAtCommit(historicalCommit, `${harDir}/oh-package.json5`)) {
    return historicalCommit;
  }

  const modifiedVersionCommit = git(
    [
      "log",
      "--diff-filter=M",
      "-1",
      "--format=%H",
      "-S",
      `"version": "${harVersion}"`,
      "--",
      `${harDir}/oh-package.json5`,
    ],
    true,
  );
  if (modifiedVersionCommit) {
    return modifiedVersionCommit;
  }

  // Never released yet at its initial version (e.g. a newly added HAR package).
  return null;
}

function hasFunctionalHarChanges(harDir, baseCommit) {
  const diffOutput = git(["diff", "--name-only", `${baseCommit}..HEAD`, "--", harDir], true);
  if (!diffOutput) {
    return false;
  }
  const ignoredBasenames = new Set(["CHANGELOG.md", "BuildProfile.ets", "oh-package-lock.json5"]);
  return diffOutput
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .some((filePath) => !ignoredBasenames.has(path.basename(filePath)));
}

function resolveReleaseDate(crateDir, version) {
  if (crateDir) {
    const crateChangelog = path.join(rootDir, crateDir, "CHANGELOG.md");
    if (fs.existsSync(crateChangelog)) {
      const content = fs.readFileSync(crateChangelog, "utf8");
      const escaped = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      const match = content.match(
        new RegExp(`^## \\[${escaped}\\](?:\\([^)]*\\))? - (\\d{4}-\\d{2}-\\d{2})`, "m"),
      );
      if (match) {
        return match[1];
      }
    }
  }
  return new Date().toISOString().slice(0, 10);
}

function extractVersionBody(changelogPath, version) {
  if (!fs.existsSync(changelogPath)) {
    return "";
  }
  const content = fs.readFileSync(changelogPath, "utf8");
  const escaped = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const headerRegex = new RegExp(
    `^## \\[${escaped}\\](?:\\([^)]*\\))?(?: - \\d{4}-\\d{2}-\\d{2})?\\s*$`,
    "m",
  );
  const match = headerRegex.exec(content);
  if (!match) {
    return "";
  }
  const start = match.index + match[0].length;
  const rest = content.slice(start);
  const nextSection = rest.search(/^## \[/m);
  return (nextSection === -1 ? rest : rest.slice(0, nextSection)).trim();
}

function collectHarCommitNotes(harDir, baseCommit) {
  if (!baseCommit) {
    return "";
  }
  const logOutput = git(
    ["log", "--no-merges", "--format=- %s", `${baseCommit}..HEAD`, "--", harDir],
    true,
  );
  return logOutput
    .split("\n")
    .map((line) => line.trim())
    .filter(
      (line) => line && !line.startsWith("- ci(release):") && !line.startsWith("- chore: release"),
    )
    .join("\n");
}

function promoteHarChangelog(
  changelogPath,
  version,
  releaseDate,
  harDir,
  baseCommit,
  pairedCrateChangelog,
) {
  if (!fs.existsSync(changelogPath)) {
    return;
  }
  const content = fs.readFileSync(changelogPath, "utf8");
  const escaped = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  if (new RegExp(`^## \\[${escaped}\\]`, "m").test(content)) {
    return;
  }
  const unreleasedMatch = /^## \[Unreleased\]\s*$/m.exec(content);
  if (!unreleasedMatch) {
    return;
  }
  const afterUnreleased = unreleasedMatch.index + unreleasedMatch[0].length;
  const rest = content.slice(afterUnreleased);
  const nextHeadingIndex = rest.search(/^## \[/m);
  const unreleasedBody = (nextHeadingIndex === -1 ? rest : rest.slice(0, nextHeadingIndex)).trim();
  const remainder = nextHeadingIndex === -1 ? "" : rest.slice(nextHeadingIndex);

  let releaseNotes = unreleasedBody;
  if (!releaseNotes) {
    releaseNotes = collectHarCommitNotes(harDir, baseCommit);
  }
  if (!releaseNotes && pairedCrateChangelog) {
    releaseNotes = extractVersionBody(pairedCrateChangelog, version);
  }
  if (!releaseNotes) {
    releaseNotes = `- Align the package version to \`${version}\` and resolve internal HAR dependencies through \`workspace:*\`.`;
  }

  const updated =
    content.slice(0, afterUnreleased) +
    `\n\n## [${version}] - ${releaseDate}\n\n${releaseNotes}\n\n` +
    remainder.replace(/^\s+/, "");
  fs.writeFileSync(changelogPath, updated);
}

function updateBuildProfile(harDir, version) {
  const profilePath = path.join(rootDir, harDir, "BuildProfile.ets");
  if (!fs.existsSync(profilePath)) {
    return;
  }
  const content = fs.readFileSync(profilePath, "utf8");
  const updated = content.replace(
    /export const HAR_VERSION = "[^"]+";/,
    `export const HAR_VERSION = "${version}";`,
  );
  if (updated !== content) {
    fs.writeFileSync(profilePath, updated);
  }
}

function discoverHarPackages() {
  const pluginDirs = fs
    .readdirSync(path.join(rootDir, "plugins"))
    .sort()
    .filter((dirName) => fs.existsSync(path.join(rootDir, "plugins", dirName, "oh-package.json5")))
    .map((dirName) => ({
      harDir: path.posix.join("plugins", dirName),
      crateDir: path.posix.join(
        "crates",
        dirName === "faultinjection" ? "plugin-fault-injection" : `plugin-${dirName}`,
      ),
    }));

  return [
    {
      harDir: "native_ability",
      crateDir: "crates/ability",
    },
    ...pluginDirs,
  ];
}

function extractVersionSection(changelogPath, version) {
  if (!fs.existsSync(changelogPath)) {
    return "";
  }
  const content = fs.readFileSync(changelogPath, "utf8");
  const escaped = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const headerRegex = new RegExp(
    `^## \\[${escaped}\\](?:\\([^)]*\\))?(?: - \\d{4}-\\d{2}-\\d{2})?\\s*$`,
    "m",
  );
  const match = headerRegex.exec(content);
  if (!match) {
    return "";
  }
  const start = match.index;
  const afterHeader = match.index + match[0].length;
  const rest = content.slice(afterHeader);
  const nextSection = rest.search(/^## \[/m);
  const end = nextSection === -1 ? content.length : afterHeader + nextSection;
  return content.slice(start, end).trim();
}

function renderReleasePrBodyWithHars(originalBody, harReleases) {
  if (!originalBody || harReleases.length === 0) {
    return originalBody;
  }

  // Strip any previously injected @ohos-rs/* bullet lines and changelog sections for idempotency.
  let body = originalBody.replace(/^\* `@ohos-rs\/[^`]+`:.*(?:\r?\n)?/gm, "");
  body = body.replace(/\n*## `@ohos-rs\/[^`]+`\s*\n\s*<blockquote>[\s\S]*?<\/blockquote>/g, "");

  const sortedHars = [...harReleases].sort((a, b) => a.harName.localeCompare(b.harName));
  const harBullets = sortedHars
    .map((item) =>
      item.isInitialRelease
        ? `* \`${item.harName}\`: ${item.newVersion}`
        : `* \`${item.harName}\`: ${item.oldVersion} -> ${item.newVersion}`,
    )
    .join("\n");

  const detailsMarker = "<details><summary><i><b>Changelog</b></i></summary><p>";
  const detailsIdx = body.indexOf(detailsMarker);
  if (detailsIdx !== -1) {
    const beforeDetails = body.slice(0, detailsIdx).trimEnd();
    const afterDetails = body.slice(detailsIdx);
    body = `${beforeDetails}\n${harBullets}\n\n${afterDetails}`;
  } else {
    body = `${body.trimEnd()}\n${harBullets}\n`;
  }

  const changelogBlocks = sortedHars
    .map((item) => {
      const changelogPath = path.join(rootDir, item.harDir, "CHANGELOG.md");
      const section =
        extractVersionSection(changelogPath, item.newVersion) || `## [${item.newVersion}]`;
      return `## \`${item.harName}\`\n\n<blockquote>\n\n${section}\n</blockquote>`;
    })
    .join("\n\n");

  const closeDetailsMarker = "</p></details>";
  const closeDetailsIdx = body.lastIndexOf(closeDetailsMarker);
  if (closeDetailsIdx !== -1) {
    const beforeClose = body.slice(0, closeDetailsIdx).trimEnd();
    const afterClose = body.slice(closeDetailsIdx);
    body = `${beforeClose}\n\n${changelogBlocks}\n\n\n${afterClose}`;
  }

  return body;
}

function updateReleasePrDescription(harReleases) {
  if (!process.env.PR_JSON || harReleases.length === 0) {
    return;
  }
  let prNumber;
  try {
    const pr = JSON.parse(process.env.PR_JSON);
    prNumber = pr?.number;
  } catch (error) {
    console.warn(`Failed to parse PR_JSON: ${error.message}`);
    return;
  }
  if (!prNumber) {
    return;
  }

  const currentBody = execFileSync(
    "gh",
    ["pr", "view", String(prNumber), "--json", "body", "--jq", ".body"],
    {
      cwd: rootDir,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "inherit"],
    },
  );
  const updatedBody = renderReleasePrBodyWithHars(currentBody, harReleases);
  if (updatedBody === currentBody) {
    return;
  }
  if (dryRun) {
    console.log(
      `[dry-run] Would update PR #${prNumber} description with ${harReleases.length} HAR release(s).`,
    );
    return;
  }
  const os = require("node:os");
  const tmpFile = path.join(os.tmpdir(), `release-pr-${prNumber}-body.md`);
  try {
    fs.writeFileSync(tmpFile, updatedBody, "utf8");
    execFileSync("gh", ["pr", "edit", String(prNumber), "--body-file", tmpFile], {
      cwd: rootDir,
      stdio: "inherit",
    });
    console.log(`Updated PR #${prNumber} description with ${harReleases.length} HAR release(s).`);
  } finally {
    if (fs.existsSync(tmpFile)) {
      fs.unlinkSync(tmpFile);
    }
  }
}

const packages = discoverHarPackages();
const pendingBumps = [];
const initialReleases = [];

for (const pkg of packages) {
  const har = readHarManifest(pkg.harDir);
  const crate = readCrateManifest(pkg.crateDir);
  const baseCommit = findHarReleaseBaseCommit(pkg.harDir, har.name, har.version, crate?.name);

  if (!baseCommit) {
    // First-time release: keep the initial version from oh-package.json5 without bumping,
    // matching release-plz's behavior for unpublished crates.
    console.log(
      `[release] ${har.name}@${har.version} (initial unpublished package; keeping initial version)`,
    );
    initialReleases.push({
      ...pkg,
      harName: har.name,
      oldVersion: null,
      newVersion: har.version,
      baseCommit: null,
      isInitialRelease: true,
    });
    continue;
  }

  const harChanged = hasFunctionalHarChanges(pkg.harDir, baseCommit);
  if (!harChanged) {
    console.log(`[skip] ${har.name}@${har.version} (no changes since ${baseCommit.slice(0, 7)})`);
    continue;
  }

  const crateBumped = crate ? compareSemver(crate.version, har.version) > 0 : false;
  const newVersion = crateBumped ? crate.version : incrementVersion(har.version);
  pendingBumps.push({
    ...pkg,
    harName: har.name,
    oldVersion: har.version,
    newVersion,
    baseCommit,
    isInitialRelease: false,
  });
}

if (pendingBumps.length === 0 && initialReleases.length === 0) {
  console.log("No HAR packages require a release or version bump.");
  process.exit(0);
}

const byVersion = new Map();
for (const item of pendingBumps) {
  const list = byVersion.get(item.newVersion) ?? [];
  list.push(item);
  byVersion.set(item.newVersion, list);
}

for (const [targetVersion, items] of byVersion.entries()) {
  const filterArg = items.map((item) => item.harName).join(",");
  console.log(`Bumping ${items.length} HAR package(s) to ${targetVersion}: ${filterArg}`);
  if (dryRun) {
    continue;
  }
  execFileSync("ohpm-rs", ["version", targetVersion, "--workspace", "--filter", filterArg], {
    cwd: rootDir,
    stdio: "inherit",
  });
  for (const item of items) {
    updateBuildProfile(item.harDir, targetVersion);
    if (!versionOnly) {
      const releaseDate = resolveReleaseDate(item.crateDir, targetVersion);
      const pairedCrateChangelog = item.crateDir
        ? path.join(rootDir, item.crateDir, "CHANGELOG.md")
        : null;
      promoteHarChangelog(
        path.join(rootDir, item.harDir, "CHANGELOG.md"),
        targetVersion,
        releaseDate,
        item.harDir,
        item.baseCommit,
        pairedCrateChangelog,
      );
    }
  }
}

if (!dryRun && pendingBumps.length > 0) {
  execFileSync("pnpm", ["exec", "oxk", "format", "**/*.{ets,js,ts,json5}", "-t=10"], {
    cwd: rootDir,
    stdio: "inherit",
  });
}

if (!versionOnly) {
  updateReleasePrDescription([...initialReleases, ...pendingBumps]);
}
