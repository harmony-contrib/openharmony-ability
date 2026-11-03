# Regenerates the Windows-host link stubs for the OHOS system libraries.
#
# Why this exists: the OHOS *-sys binding crates declare
# `#[link(name = "ace_ndk.z")]`-style dependencies on device-only system
# libraries. Linking this workspace on a Windows host (cargo test /
# doctests) fails with LNK1181 "cannot open input file" before any Rust
# code runs. This script fabricates the expected import names:
#
#   - one empty archive per requested name (satisfies the link line,
#     provides no symbols);
#   - ohos-host-stubs.lib  - all ArkUI/native symbols compiled from stubs.rs
#     (full symbol set recorded across symbols_round1-5.txt);
#   - ohinputmethod.lib    - copy of the host stub archive (the
#     ohos-input-method-sys `#[link]` name puts it on every host link, so
#     the ArkUI/IME stub symbols resolve through it);
#   - ohweb.lib            - ArkWeb symbols from stub-web.rs (recorded in
#     symbols_web.txt).
#
# Output: target/host-stub-libs/ (wired into host builds via the
# [target.x86_64-pc-windows-msvc] rustflags in .cargo/config.toml).
# Cross builds (aarch64/x86_64-unknown-linux-ohos) are unaffected.
#
# Idempotent: reruns rebuild every output from the checked-in sources.
#
# New unresolved `OH_*` symbol (LNK2019): add
# `#[no_mangle] extern "C" fn <SymbolName>() {}` DIRECTLY to stubs.rs
# (ArkUI/IME/XComponent/dlopen/hilog/resource-manager family, plus the
# round-4 ArkWeb scheme set) or stub-web.rs (ArkWeb scheme-handler/resource
# family pulled by links that include ohos-web-sys), then rerun this script.
# It compiles those two sources into the archives - that compile leg NEVER
# reads the symbols_roundN.txt / symbols_web.txt files; those are documentation
# records only. A separate verification leg (Assert-SymbolRecord) DOES read
# them: it diff-verifies each record against the symbol set extracted from the
# sources on every run (update the record in the same change or the script
# fails with a drift error). It also drift-checks the cross-repo set-bounds sentinel constant
# recorded in sentinel_constants.txt (before matching, the check strips
# line comments, doc-comment interior lines, and multi-line /* */ block
# comment spans, and anchors the pattern at line start, so a comment
# echoing the declaration form cannot satisfy it). The drift checks prove
# the records do not rot - they do NOT prove a link will succeed. See
# host-stubs/README.md for the full workflow.

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$stubDir  = Join-Path $repoRoot "host-stubs"
$outDir   = Join-Path $repoRoot "target\host-stub-libs"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# --- locate MSVC lib.exe (archive tool) via vswhere -----------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found; install Visual Studio 2022 Build Tools (C++ workload)."
}
$libExe = & $vswhere -latest -products * -find '**\lib.exe' | Select-Object -First 1
if (-not $libExe) {
    throw "MSVC lib.exe not found; install the Visual Studio C++ toolset."
}
Write-Host "using lib.exe: $libExe"

function Invoke-RustcObj([string]$Source, [string]$ObjOut) {
    & rustc --edition 2021 --crate-type lib --emit=obj `
        -C codegen-units=1 -C opt-level=0 `
        $Source "-o" $ObjOut
    if ($LASTEXITCODE -ne 0) { throw "rustc failed for $Source" }
}

function Invoke-LibArchive([string]$Obj, [string]$LibOut) {
    & $libExe /NOLOGO ("/OUT:" + $LibOut) $Obj
    if ($LASTEXITCODE -ne 0) { throw "lib.exe failed for $LibOut" }
}

# --- 0. symbol-record drift check -------------------------------------------
# The symbols_round*.txt / symbols_web.txt records are documentation of what
# each stub source covers. This script never consumes them for building, but it
# DOES verify they match the sources, so a symbol added to stubs.rs without
# updating the records fails here instead of silently rotting the docs.
function Get-StubSymbols([string]$Source) {
    $names = Select-String -Path $Source -Pattern 'extern "C" fn (\w+)\(' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
    if (-not $names -or @($names).Count -eq 0) {
        throw ('no extern "C" symbols found in ' + $Source)
    }
    return @($names)
}

function Assert-SymbolRecord([string[]]$Symbols, [string[]]$RecordPaths, [string]$SourceName) {
    $recorded = @()
    foreach ($path in $RecordPaths) {
        if (-not (Test-Path $path)) {
            throw "symbol record missing: $path (expected for $SourceName)"
        }
        $recorded += Get-Content $path | Where-Object { $_.Trim() -ne "" }
    }
    $recorded = @($recorded | Sort-Object -Unique)
    $actual = @($Symbols | Sort-Object -Unique)
    $drift = Compare-Object -ReferenceObject $recorded -DifferenceObject $actual
    if ($drift) {
        $drift | ForEach-Object {
            $side = if ($_.SideIndicator -eq "<=") { "record-only" } else { "source-only" }
            Write-Host "  $side $($_.InputObject)"
        }
        throw "$SourceName symbols drifted from the symbols_round*/symbols_web records; update the record files in the same change"
    }
    Write-Host ("symbol records verified: " + $actual.Count + " symbols across " + $RecordPaths.Count + " record file(s) for " + $SourceName)
}

$stubSymbols = Get-StubSymbols (Join-Path $stubDir "stubs.rs")
Assert-SymbolRecord $stubSymbols @(
    (Join-Path $stubDir "symbols_round1.txt"),
    (Join-Path $stubDir "symbols_round2.txt"),
    (Join-Path $stubDir "symbols_round3.txt"),
    (Join-Path $stubDir "symbols_round4.txt"),
    (Join-Path $stubDir "symbols_round5.txt")
) "stubs.rs"
$webSymbols = Get-StubSymbols (Join-Path $stubDir "stub-web.rs")
Assert-SymbolRecord $webSymbols @((Join-Path $stubDir "symbols_web.txt")) "stub-web.rs"

# --- 0b. cross-repo sentinel-constant drift check -----------------------------
# F12: the ArkTS set-bounds sentinel literal (i32::MIN) is part of the
# cross-repo wire contract with tauri-runtime-wry and no host UT can observe
# the ArkTS-only wire, so it is pinned by a record file the same way the
# symbol sets are. As with the symbol records this verifies documentation
# does not rot - it does NOT verify that a link will succeed. ability-R5: the
# check strips comments before matching (line comments, doc-comment interior
# lines, and multi-line /* */ block comment spans) and anchors the pattern at
# line start, so a comment echoing the declaration shape cannot satisfy it.
function Assert-SentinelConstants([string]$RecordPath) {
    if (-not (Test-Path $RecordPath)) {
        throw "sentinel record missing: $RecordPath"
    }
    $entries = Get-Content $RecordPath |
        Where-Object { $_.Trim() -ne "" -and -not $_.Trim().StartsWith("#") }
    if (-not $entries -or @($entries).Count -eq 0) {
        throw "sentinel record empty: $RecordPath"
    }
    foreach ($entry in @($entries)) {
        $parts = @($entry.Trim() -split '\s+')
        if ($parts.Count -ne 3) {
            throw ("malformed sentinel record entry (expected '<file> <name> <literal>'): " + $entry)
        }
        $file = $parts[0]; $name = $parts[1]; $literal = $parts[2]
        $sourcePath = Join-Path $repoRoot $file
        if (-not (Test-Path $sourcePath)) {
            throw "sentinel source file missing: $file"
        }
        # ability-R5: match only real declaration lines. Comment text is
        # stripped first and the pattern is anchored at line start, so a
        # comment echoing the declaration form (e.g. prose quoting
        # 'const <name>: number = <literal>;') must not satisfy the check.
        # Round 3 (AR3-1): the strip is a small two-state scanner, not a
        # line-shape filter. The previous filter only dropped lines that
        # START with '//' or '*', which let the bare interior lines of a
        # multi-line /* */ block comment survive - a block comment echoing
        # the declaration could then satisfy the anchored pattern and fake a
        # pass while the real declaration was gone. The scanner removes:
        #   - '//' line comments (the rest of the line);
        #   - '/*' ... '*/' block comment spans across lines (bare interior
        #     lines included), keeping any code that follows the closing
        #     '*/' on that line;
        #   - lines whose first non-blank character is '*' (doc-comment
        #     interior shape, previous rule kept).
        # It is a scanner, not a lexer: string literals are not tracked, so
        # '//' or '/*' inside a string also strips. That only ever
        # over-strips, which fails closed - it cannot resurrect comment text
        # as a declaration.
        $codeLines = @()
        $inBlock = $false
        foreach ($line in (Get-Content $sourcePath)) {
            if ($inBlock) {
                $close = $line.IndexOf("*/", [System.StringComparison]::Ordinal)
                if ($close -lt 0) { continue }
                $inBlock = $false
                $line = $line.Substring($close + 2)
            }
            if ($line.TrimStart().StartsWith("*")) { continue }
            $code = New-Object System.Text.StringBuilder
            $i = 0
            while ($i -lt $line.Length) {
                $two = if ($i + 1 -lt $line.Length) { $line.Substring($i, 2) } else { "" }
                if ($two -ceq "/*") {
                    $close = $line.IndexOf("*/", $i + 2, [System.StringComparison]::Ordinal)
                    if ($close -ge 0) {
                        # complete pair on this line: drop the comment, keep the tail
                        $i = $close + 2
                    } else {
                        # unclosed: the rest of the line opens a block span
                        $inBlock = $true
                        break
                    }
                }
                elseif ($two -ceq "//") {
                    break
                }
                else {
                    [void]$code.Append($line[$i])
                    $i += 1
                }
            }
            $codeText = $code.ToString()
            if ($codeText.Trim().Length -gt 0) {
                $codeLines += $codeText
            }
        }
        $pattern = ('^\s*const\s+' + [regex]::Escape($name) +
            '\s*:\s*number\s*=\s*' + [regex]::Escape($literal) + '\s*;')
        $matched = $false
        foreach ($codeLine in $codeLines) {
            if ($codeLine -cmatch $pattern) { $matched = $true; break }
        }
        if (-not $matched) {
            throw ("sentinel constant drifted: $file no longer declares " +
                "'const ${name}: number = ${literal};' (uncommented, at line start) - " +
                "the i32::MIN set-bounds sentinel is a cross-repo wire contract " +
                "with tauri-runtime-wry; update host-stubs/sentinel_constants.txt " +
                "only if the contract itself changed on both sides")
        }
        Write-Host ("sentinel constant verified: $name = $literal in $file")
    }
}
Assert-SentinelConstants (Join-Path $stubDir "sentinel_constants.txt")

# --- 1. empty per-name archives -------------------------------------------
# Compile one empty object, then archive it under every link name the
# binding crates request. Content never matters for these; existence does.
$emptyRs  = Join-Path $outDir "empty.rs"
$emptyObj = Join-Path $outDir "empty.obj"
Set-Content -Path $emptyRs -Value "" -Encoding ascii
Invoke-RustcObj $emptyRs $emptyObj

$emptyNames = @(
    "ace_ndk.z", "image_ndk.z", "image_packer", "image_packer_ndk.z",
    "image_receiver", "image_receiver_ndk.z", "image_source",
    "image_source_ndk.z", "native_buffer", "native_display_manager",
    "native_drawing", "ohimage", "ohresmgr", "picture", "pixelmap",
    "pixelmap_ndk.z", "rawfile.z", "udmf", "hilog_ndk.z"
)
foreach ($n in $emptyNames) {
    Invoke-LibArchive $emptyObj (Join-Path $outDir ($n + ".lib"))
}
Write-Host ("empty stub archives written: " + $emptyNames.Count)

# --- 2. ArkUI/native symbol archive (stubs.rs) ----------------------------
$stubsObj = Join-Path $outDir "stubs.obj"
Invoke-RustcObj (Join-Path $stubDir "stubs.rs") $stubsObj
$hostStubsLib = Join-Path $outDir "ohos-host-stubs.lib"
Invoke-LibArchive $stubsObj $hostStubsLib

# ohinputmethod is the `#[link]` name ohos-input-method-sys puts on every
# host link; ship the full stub archive under that name so the ArkUI/IME
# extern symbols resolve.
Copy-Item $hostStubsLib (Join-Path $outDir "ohinputmethod.lib") -Force
Write-Host "ohos-host-stubs.lib + ohinputmethod.lib written"

# --- 3. ArkWeb symbol archive (stub-web.rs) --------------------------------
$webObj = Join-Path $outDir "stub-web.obj"
Invoke-RustcObj (Join-Path $stubDir "stub-web.rs") $webObj
Invoke-LibArchive $webObj (Join-Path $outDir "ohweb.lib")
Write-Host "ohweb.lib written"

Write-Host "host stubs regenerated in $outDir"
