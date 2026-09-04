# Aggregates the 17 bridge plugins into the single `@ohos-rs/ability` HAR.
#
# Run by pack.bat AFTER the base native_ability metadata + ets tree have been
# copied into package/. Produces a self-contained HAR (Strategy A):
#   - each plugin source file is copied under package/src/main/ets/plugins/<name>/
#     with its `from "@ohos-rs/ability"` import rewritten to the internal barrel
#   - an internal barrel `ability_exports.ets` is generated from the base index.ets
#     (paths rewritten to be relative to package/src/main/ets/) so plugins resolve
#     base symbols without importing their own module by name (no cycle)
#   - the 17 plugin classes are appended as re-exports to package/index.ets so
#     consumers import them from `@ohos-rs/ability` directly
#
# Plugins stay standalone-buildable: their source still uses
# `from "@ohos-rs/ability"`; the rewrite only happens to the copies in package/.

param([string]$ScriptDir)

$ErrorActionPreference = 'Stop'

if (-not $ScriptDir) { $ScriptDir = $PSScriptRoot }
# Trim trailing backslashes AND quotes: pack.bat passes "%SCRIPT_DIR%" whose
# trailing backslash escapes the closing quote in cmd's parser, so the arg
# arrives with a literal trailing quote (which Join-Path then bakes into every
# path, failing Test-Path with ItemExistsArgumentError).
$ScriptDir = $ScriptDir.Trim('"\')

# (plugin-dir, exported-class) — the 17 core bridge plugins.
$plugins = @(
  @{ name = 'accessibility';   cls = 'AccessibilityPlugin' },
  @{ name = 'app-control';     cls = 'AppControlPlugin' },
  @{ name = 'account';         cls = 'AccountPlugin' },
  @{ name = 'autostart';       cls = 'AutostartPlugin' },
  @{ name = 'clipboard';       cls = 'ClipboardPlugin' },
  @{ name = 'deep-link';       cls = 'DeepLinkPlugin' },
  @{ name = 'files';           cls = 'FilesPlugin' },
  @{ name = 'global-shortcut'; cls = 'GlobalShortcutPlugin' },
  @{ name = 'menu';            cls = 'MenuPlugin' },
  @{ name = 'permission';      cls = 'PermissionPlugin' },
  @{ name = 'process';         cls = 'ProcessPlugin' },
  @{ name = 'resource';        cls = 'ResourcePlugin' },
  @{ name = 'statusbar';       cls = 'StatusbarPlugin' },
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

# 3. Append plugin re-exports to package/index.ets (base exports stay first,
#    so plugin classes — which extend base classes — always resolve).
$pkgIdx = Join-Path $ScriptDir 'package\index.ets'
$lines = @(
  '',
  '// === Bridge plugins (aggregated from plugins/ - see pack-plugins.ps1) ==='
)
foreach ($p in $plugins) {
  $lines += "export { $($p.cls) } from `"./src/main/ets/plugins/$($p.name)/$($p.cls)`";"
}

# 4. Generate `plugins/all.ets`: a ready-made factory array covering every
#    bridge plugin in this package. Apps assign it to
#    NativeAbility#bridgePlugins so newly added bridge plugins flow to apps
#    on package update, without regenerating their EntryAbility. The
#    LazyPlugin factories are stateless — sharing the array across Ability
#    instances is safe (each host calls create() for its own plugin
#    instances). Lives in its own module because `LazyPlugin` must be
#    imported for the type annotation, and package/index.ets only re-exports
#    it.
$allEts = @(
  "import { LazyPlugin } from '../ability/type';",
  ''
)
foreach ($p in $plugins) {
  $allEts += "import { $($p.cls) } from './$($p.name)/$($p.cls)';"
}
$allEts += @(
  '',
  '// Ready-made factory array for NativeAbility#bridgePlugins (see pack-plugins.ps1).',
  'export const allBridgePlugins: LazyPlugin[] = ['
)
foreach ($p in $plugins) {
  $allEts += "  new LazyPlugin(() => new $($p.cls)()),"
}
$allEts += ']'
$allPath = Join-Path $pluginsDir 'all.ets'
[System.IO.File]::WriteAllText($allPath, ($allEts -join "`r`n") + "`r`n", $utf8NoBom)
Write-Host "  all:    $allPath"

$lines += 'export { allBridgePlugins } from "./src/main/ets/plugins/all";'

$append = ($lines -join "`r`n") + "`r`n"
[System.IO.File]::AppendAllText($pkgIdx, $append, $utf8NoBom)
Write-Host "  index:  appended $($plugins.Count) plugin re-exports + allBridgePlugins to $pkgIdx"
