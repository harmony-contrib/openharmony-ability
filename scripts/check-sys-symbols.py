#!/usr/bin/env python3
"""Check that every `sys.symbol.*` referenced in ArkTS sources exists in the minimum
supported SDK (5.0.0(12), see tauri-cli build-profile.json5).

The ArkTS compiler resolves `$r("sys.symbol.x")` at build time against the *build*
SDK's sysResource table; a symbol absent from that table fails the HAP build. But the
table is per-SDK-version: a symbol present in a newer build SDK (e.g. person_3,
circle_fill, first public in API 20) breaks any app built against the 5.0.0(12) floor.
Every reference must therefore be a subset of the 5.0.0(12) table, checked here against
the frozen baseline scripts/sys-symbols-api12.txt (regenerate via
gen-sys-symbols-baseline.py).

(D-batch: the original check scanned only the nativeIcon whitelist labels in
native_ability/.../MenuBarComponent.ets. The upstream reorg moved that whitelist into
plugins/menu/MenuBarComponent.ets and added sys.symbol references in three more files
(plugins/menu/MenuPopup.ets, plugins/webview/NewWindowDialog.ets,
plugins/window/PromptDialogs.ets), so the scan now covers every .ets file under
native_ability/ and plugins/ — both `case "sys.symbol.<name>"` whitelist labels and
direct `$r("sys.symbol.<name>")` resource references.)

Usage:
    python3 scripts/check-sys-symbols.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = Path(__file__).resolve().parent / "sys-symbols-api12.txt"
SCAN_ROOTS = [ROOT / "native_ability", ROOT / "plugins"]

SYMBOL_RE = re.compile(r'"sys\.symbol\.(\w+)"')


def main():
    baseline = set(BASELINE.read_text(encoding="utf-8").split())
    symbols = set()
    files = 0
    for scan_root in SCAN_ROOTS:
        for path in sorted(scan_root.rglob("*.ets")):
            files += 1
            symbols.update(SYMBOL_RE.findall(path.read_text(encoding="utf-8")))
    missing = sorted(symbols - baseline)
    print(f"baseline symbols (min SDK 5.0.0/12): {len(baseline)}")
    print(f"scanned .ets files:                  {files}")
    print(f"referenced sys.symbol names:         {len(symbols)}")
    if missing:
        print(f"ERROR: {len(missing)} symbol(s) missing from min SDK 5.0.0(12):")
        for sym in missing:
            print(f"  sys.symbol.{sym}")
        print("Fix: pick an equivalent symbol that exists in 5.0.0(12), or drop the case")
        print("(falls through to `default` -> null). See tauri issue #120.")
        return 1
    print("OK: all references are a subset of min SDK 5.0.0(12) sysResource table.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
