#!/usr/bin/env python3
"""Check that every `sys.symbol.*` in the nativeIcon whitelist exists in the minimum
supported SDK (5.0.0(12), see tauri-cli build-profile.json5).

The ArkTS compiler resolves `$r("sys.symbol.x")` at build time against the *build*
SDK's sysResource table; a symbol absent from that table fails the HAP build. But the
table is per-SDK-version: a symbol present in a newer build SDK (e.g. person_3,
circle_fill, first public in API 20) breaks any app built against the 5.0.0(12) floor.
The whitelist therefore must be a subset of the 5.0.0(12) table, checked here against
the frozen baseline scripts/sys-symbols-api12.txt (regenerate via
gen-sys-symbols-baseline.py).

Extracts the `case "sys.symbol.<name>"` labels from MenuBarComponent.ets and fails
if any is missing from the baseline.

Usage:
    python3 scripts/check-sys-symbols.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = Path(__file__).resolve().parent / "sys-symbols-api12.txt"
WHITELIST = ROOT / "native_ability/src/main/ets/components/MenuBarComponent.ets"

CASE_RE = re.compile(r'case "sys\.symbol\.([\w_]+)"')


def main():
    baseline = set(BASELINE.read_text(encoding="utf-8").split())
    source = WHITELIST.read_text(encoding="utf-8")
    symbols = set(CASE_RE.findall(source))

    missing = sorted(symbols - baseline)
    print(f"baseline symbols (min SDK 5.0.0/12): {len(baseline)}")
    print(f"whitelist symbols:                   {len(symbols)}")
    if missing:
        print(f"ERROR: {len(missing)} symbol(s) missing from min SDK 5.0.0(12):")
        for sym in missing:
            print(f"  sys.symbol.{sym}")
        print("Fix: pick an equivalent symbol that exists in 5.0.0(12), or drop the case")
        print("(falls through to `default` -> null). See tauri issue #120.")
        return 1
    print("OK: whitelist is a subset of min SDK 5.0.0(12) sysResource table.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
