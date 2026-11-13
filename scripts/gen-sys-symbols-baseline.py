#!/usr/bin/env python3
"""Regenerate scripts/sys-symbols-api12.txt (public symbol baseline of the minimum
supported SDK, OpenHarmony 5.0.0 / API 12).

The baseline is generated from `global_system_resources`'s `id_defined.json` at the
OpenHarmony-5.0-Release branch, applying the same filtering as the SDK's
`generateSysResource.py` (developtools_ace_ets2bundle): keep entries whose type is
`symbol`, drop entries whose flags contain `private`. Symbol ids (`order + 0x7800000`)
are not needed for the whitelist check, only the names.

Note: HarmonyOS 5.0.0(12) is the framework's compatibleSdkVersion floor (tauri-cli
build-profile.json5). Symbols added in later SDKs (e.g. person_3, circle_fill, first
public in API 20) must NOT enter the baseline; the whitelist check guards against that.

Usage:
    python3 scripts/gen-sys-symbols-baseline.py                # fetch from gitee
    python3 scripts/gen-sys-symbols-baseline.py --url <file>   # use a local file
"""

import argparse
import json
import sys
import urllib.request
from pathlib import Path

DEFAULT_URL = (
    "https://gitee.com/openharmony/global_system_resources/raw/"
    "OpenHarmony-5.0-Release/systemres/main/resources/base/element/id_defined.json"
)
OUT = Path(__file__).resolve().parent / "sys-symbols-api12.txt"


def public_symbols(records):
    return sorted(
        item["name"]
        for item in records
        if item["type"] == "symbol"
        and not ("flags" in item and "private" in item["flags"])
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=DEFAULT_URL, help="id_defined.json URL or local path")
    args = parser.parse_args()

    if args.url.startswith(("http://", "https://")):
        with urllib.request.urlopen(args.url, timeout=30) as resp:
            data = json.load(resp)
    else:
        with open(args.url, encoding="utf-8") as fp:
            data = json.load(fp)

    symbols = public_symbols(data["record"])
    OUT.write_text("\n".join(symbols) + "\n", encoding="utf-8")
    print(f"wrote {len(symbols)} public symbols to {OUT}")


if __name__ == "__main__":
    sys.exit(main())
