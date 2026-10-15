# Aggregates the 20 bridge plugins into the single `@ohos-rs/ability` HAR.
#
# Run by pack.bat AFTER the base native_ability metadata + ets tree have been
# copied into package/. Produces a self-contained HAR (Strategy A):
#   - each plugin source file is copied under package/src/main/ets/plugins/<name>/
#     with its `from "@ohos-rs/ability"` import rewritten to the internal barrel
#   - a plugin may depend on sibling plugin packages (rs<->ets correspondence:
#     e.g. plugins/statusbar depends on @ohos-rs/ability-plugin-menu). Each
#     such `from "@ohos-rs/ability-plugin-<name>"` import is rewritten to the
#     sibling's inlined copy via a generated `plugins/<name>/exports.ets` barrel
#     (built from that plugin's own index.ets the same way the base barrel is)
#   - an internal barrel `ability_exports.ets` is generated from the base index.ets
#     (paths rewritten to be relative to package/src/main/ets/) so plugins resolve
#     base symbols without importing their own module by name (no cycle)
#   - the 20 plugin classes are appended as re-exports to package/index.ets so
#     consumers import them from `@ohos-rs/ability` directly
#
# Plugins stay standalone-buildable: their source still uses
# `from "@ohos-rs/ability"` / `from "@ohos-rs/ability-plugin-<name>"`; the
# rewrites only happen to the copies in package/. A final guard rejects any
# residual `@ohos-rs/*` specifier so the aggregate HAR can never ship
# unresolvable imports.

param([string]$ScriptDir)

$ErrorActionPreference = 'Stop'

if (-not $ScriptDir) { $ScriptDir = $PSScriptRoot }
# Trim trailing backslashes AND quotes: pack.bat passes "%SCRIPT_DIR%" whose
# trailing backslash escapes the closing quote in cmd's parser, so the arg
# arrives with a literal trailing quote (which Join-Path then bakes into every
# path, failing Test-Path with ItemExistsArgumentError).
$ScriptDir = $ScriptDir.Trim('"\')

# (plugin-dir, exported-class) — the 20 core bridge plugins.
$plugins = @(
  @{ name = 'accessibility';   cls = 'AccessibilityPlugin' },
  @{ name = 'app-control';     cls = 'AppControlPlugin' },
  @{ name = 'account';         cls = 'AccountPlugin' },
  @{ name = 'autostart';       cls = 'AutostartPlugin' },
  @{ name = 'clipboard';       cls = 'ClipboardPlugin'; exports = 'ClipboardPlugin, ClipboardPluginOptions' },
  @{ name = 'deep-link';       cls = 'DeepLinkPlugin' },
  @{ name = 'faultinjection';  cls = 'FaultInjectionPlugin' },
  @{ name = 'files';           cls = 'FilesPlugin' },
  @{ name = 'global-shortcut'; cls = 'GlobalShortcutPlugin' },
  @{ name = 'menu';            cls = 'MenuPlugin' },
  @{ name = 'notification';    cls = 'NotificationPlugin'; exports = 'NotificationPlugin, NotificationPluginOptions' },
  @{ name = 'permission';      cls = 'PermissionPlugin' },
  @{ name = 'process';         cls = 'ProcessPlugin' },
  @{ name = 'resource';        cls = 'ResourcePlugin' },
  @{ name = 'statusbar';       cls = 'StatusbarPlugin' },
  @{ name = 'system-state';    cls = 'SystemStatePlugin' },
  @{ name = 'updater';         cls = 'UpdaterPlugin' },
  @{ name = 'url';             cls = 'UrlPlugin' },
  @{ name = 'webview';         cls = 'WebviewPlugin' },
  @{ name = 'window';          cls = 'WindowPlugin' }
)

$pkgEts     = Join-Path $ScriptDir 'package\src\main\ets'
$pluginsDir = Join-Path $pkgEts 'plugins'
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

# Wipe any previous plugin aggregation so removed plugins don't linger.
if (Test-Path $pluginsDir) { Remove-Item -Recurse -Force $pluginsDir }
New-Item -ItemType Directory -Force -Path $pluginsDir | Out-Null

# Cross-plugin dependencies (rs<->ets correspondence: a plugin package may
# depend on sibling plugin packages, e.g. plugins/statusbar depends on
# @ohos-rs/ability-plugin-menu). Discover them by scanning each plugin's
# oh-package.json5 for @ohos-rs/ability-plugin-<name> dependency keys, then
# rewrite those imports to the sibling's inlined copy (see below). oh-package
# files are JSON5 — trailing commas break ConvertFrom-Json, so scan by regex.
$crossDeps = @{}   # plugin name -> set of sibling plugin names it depends on
$depKeyRe = [regex]'"@ohos-rs/ability-plugin-([\w-]+)"\s*:'
foreach ($p in $plugins) {
  $ohPackage = Join-Path $ScriptDir "plugins\$($p.name)\oh-package.json5"
  $targets = New-Object System.Collections.Generic.HashSet[string]
  foreach ($m in $depKeyRe.Matches([System.IO.File]::ReadAllText($ohPackage))) {
    $target = $m.Groups[1].Value
    if ($target -ne $p.name) { [void]$targets.Add($target) }
  }
  $crossDeps[$p.name] = $targets
}

# 1. Copy each plugin's source files, rewriting the base-package import to the barrel.
#    A plugin may ship more than its main class file (e.g. webview's
#    NewWindowDialog.ets helper) — copy ALL .ets files under the plugin's ets
#    dir, preserving subdirectory layout, so intra-plugin relative imports
#    (e.g. `from "./NewWindowDialog"`) resolve inside the aggregated HAR.
foreach ($p in $plugins) {
  $srcEtsDir = Join-Path $ScriptDir "plugins\$($p.name)\src\main\ets"
  if (-not (Test-Path $srcEtsDir)) {
    throw "Plugin ets dir not found: $srcEtsDir"
  }
  $dstDir = Join-Path $pluginsDir $p.name
  New-Item -ItemType Directory -Force -Path $dstDir | Out-Null

  $srcFiles = Get-ChildItem -Path $srcEtsDir -Recurse -File -Filter '*.ets'
  foreach ($f in $srcFiles) {
    $rel = $f.FullName.Substring($srcEtsDir.Length + 1)
    $dst = Join-Path $dstDir $rel
    $dstParent = Split-Path -Parent $dst
    if (-not (Test-Path $dstParent)) { New-Item -ItemType Directory -Force -Path $dstParent | Out-Null }

    $content = [System.IO.File]::ReadAllText($f.FullName)
    $content = $content.Replace('from "@ohos-rs/ability"', 'from "../../ability_exports"')
    # Sibling plugin imports (e.g. statusbar -> menu) point at the sibling's
    # inlined copy through its generated exports barrel.
    foreach ($target in $crossDeps[$p.name]) {
      $content = $content.Replace("from `"@ohos-rs/ability-plugin-$target`"", "from `"../$target/exports`"")
    }
    [System.IO.File]::WriteAllText($dst, $content, $utf8NoBom)
  }
  # Sanity: the main class file must be present.
  $clsFile = Join-Path $dstDir "$($p.cls).ets"
  if (-not (Test-Path $clsFile)) {
    throw "Plugin class file missing after copy: $clsFile"
  }
  Write-Host "  plugin: $($p.name) -> $dstDir ($($srcFiles.Count) file(s))"
}

# 2. Generate the internal barrel from the base index.ets.
#    Source index uses `./src/main/ets/<path>`; from package/src/main/ets/ the
#    same files are at `./<path>`, so strip the `./src/main/ets/` prefix.
$barrel    = Join-Path $pkgEts 'ability_exports.ets'
$idxSource = Join-Path $ScriptDir 'native_ability\index.ets'
$idxContent = [System.IO.File]::ReadAllText($idxSource)
$idxContent = $idxContent.Replace('./src/main/ets/', './')
[System.IO.File]::WriteAllText($barrel, $idxContent, $utf8NoBom)
Write-Host "  barrel: $barrel"

# 2b. Generate an `exports.ets` barrel for every plugin that another plugin
#     imports cross-package (discovered above). Same prefix-strip trick as the
#     base barrel: plugins/<name>/index.ets uses `./src/main/ets/<path>` and the
#     inlined copy sits flat next to the barrel. Importers reference it as
#     `../<name>/exports`.
$referenced = New-Object System.Collections.Generic.HashSet[string]
foreach ($targets in $crossDeps.Values) {
  foreach ($t in $targets) { [void]$referenced.Add($t) }
}
foreach ($name in $referenced) {
  $srcIdx = Join-Path $ScriptDir "plugins\$name\index.ets"
  if (-not (Test-Path $srcIdx)) {
    throw "Cross-plugin dependency target has no index.ets: $srcIdx"
  }
  $refBarrel = Join-Path $pluginsDir "$name\exports.ets"
  $refContent = [System.IO.File]::ReadAllText($srcIdx)
  $refContent = $refContent.Replace('./src/main/ets/', './')
  [System.IO.File]::WriteAllText($refBarrel, $refContent, $utf8NoBom)
  Write-Host "  xbarrel: $refBarrel"
}

# 3. Append plugin re-exports to package/index.ets (base exports stay first,
#    so plugin classes — which extend base classes — always resolve).
$pkgIdx = Join-Path $ScriptDir 'package\index.ets'
$lines = @(
  '',
  '// === Bridge plugins (aggregated from plugins/ - see pack-plugins.ps1) ==='
)
foreach ($p in $plugins) {
  $exports = if ($p.exports) { $p.exports } else { $p.cls }
  $lines += "export { $exports } from `"./src/main/ets/plugins/$($p.name)/$($p.cls)`";"
}

# 4. Generate `plugins/all.ets`: an explicitly configured factory for every
#    bridge plugin. Business code must provide its clipboard MIME and notification
#    scheme. Each host still creates independent plugin instances through LazyPlugin.
$allEts = @(
  "import { LazyPlugin } from '../ability/type';",
  ''
)
foreach ($p in $plugins) {
  $exports = if ($p.exports) { $p.exports } else { $p.cls }
  $allEts += "import { $exports } from './$($p.name)/$($p.cls)';"
}
$allEts += @(
  '',
  'export interface AllBridgePluginOptions {',
  '  clipboard: ClipboardPluginOptions;',
  '  notification: NotificationPluginOptions;',
  '}',
  '',
  'export function createAllBridgePlugins(options: AllBridgePluginOptions): LazyPlugin[] {',
  '  if (!options?.clipboard || !options?.notification) {',
  '    throw new Error("createAllBridgePlugins requires clipboard and notification options");',
  '  }',
  '  const clipboard: ClipboardPluginOptions = { metadataMimeType: options.clipboard.metadataMimeType };',
  '  const notification: NotificationPluginOptions = { scheme: options.notification.scheme };',
  '  return ['
)
foreach ($p in $plugins) {
  $argument = if ($p.name -eq 'clipboard') { 'clipboard' } elseif ($p.name -eq 'notification') { 'notification' } else { '' }
  $allEts += "    new LazyPlugin(() => new $($p.cls)($argument)),"
}
$allEts += @('  ];', '}')
$allPath = Join-Path $pluginsDir 'all.ets'
[System.IO.File]::WriteAllText($allPath, ($allEts -join "`r`n") + "`r`n", $utf8NoBom)
Write-Host "  all:    $allPath"

$lines += 'export { createAllBridgePlugins, AllBridgePluginOptions } from "./src/main/ets/plugins/all";'

$append = ($lines -join "`r`n") + "`r`n"
[System.IO.File]::AppendAllText($pkgIdx, $append, $utf8NoBom)
Write-Host "  index:  appended $($plugins.Count) plugin re-exports + createAllBridgePlugins to $pkgIdx"

# 5. Guard: the aggregate HAR must be self-contained. After all rewrites, no
#    `@ohos-rs/*` package specifier may remain anywhere under package/ — a
#    leftover means the aggregate would ship imports that resolve to nothing
#    inside the HAR (the consumer only installs @ohos-rs/ability). Matches
#    `from "@ohos-rs/..."` clauses (including the closing line of a multi-line
#    import block) on non-comment lines — the core index.ets documents this
#    very rewrite in a comment that quotes the specifier verbatim.
$bad = Get-ChildItem -Path (Join-Path $ScriptDir 'package') -Recurse -File -Filter '*.ets' |
  Select-String -Pattern '^(?!\s*//).*\bfrom\s+["'']@ohos-rs/[\w-]+["'']'
if ($bad) {
  foreach ($b in $bad) {
    Write-Host "  UNREWRITTEN: $($b.Path):$($b.LineNumber): $($b.Line.Trim())"
  }
  throw "Unrewritten @ohos-rs package import/export statement(s) remain under package/ — the aggregate HAR would not be self-contained"
}
Write-Host "  guard:  no residual @ohos-rs package specifiers under package/"
