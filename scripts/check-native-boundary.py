#!/usr/bin/env python3
"""Reject direct sys dependencies and runtime native capability loaders."""
from pathlib import Path
import re
import subprocess
import tomllib


def dependency_errors(table, location):
    errors = []
    for name, dependency in table.items():
        package = dependency.get("package", name) if isinstance(dependency, dict) else name
        if package == "libloading" or re.search(r"(?:^|-)sys(?:-|$)", package):
            errors.append(f"{location}: forbidden direct dependency {name} ({package})")
        if isinstance(dependency, dict) and "dyn-symbols" in dependency.get("features", []):
            errors.append(f"{location}: runtime symbol loading enabled on {name}")
    return errors


def manifest_errors(document, location):
    errors = []
    for section in ("dependencies", "dev-dependencies", "build-dependencies"):
        errors.extend(dependency_errors(document.get(section, {}), location))
    errors.extend(dependency_errors(document.get("workspace", {}).get("dependencies", {}), location))
    for target, table in document.get("target", {}).items():
        errors.extend(manifest_errors(table, f"{location} [{target}]"))
    for name, features in document.get("features", {}).items():
        if any(feature.split("/")[-1] == "dyn-symbols" for feature in features):
            errors.append(f"{location}: feature {name} enables runtime symbol loading")
    return errors


def source_errors(source, location, rust):
    # Comments can document the restriction without triggering it.
    source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
    patterns = [
        (r"\blibloading\b", "runtime library loader"),
        (r"\b(?:dlopen|dlsym|dlmopen|LoadLibrary(?:A|W)?|GetProcAddress)\s*\(", "runtime symbol probe"),
    ]
    if rust:
        patterns += [
            (r'\bextern\s+"[^"]+"\s*\{', "local FFI import (add a binding wrapper)"),
            (r"\b(?:use|extern\s+crate)\s+\w+_sys\b", "direct sys import"),
            (r"\b(?:OH_|OHOS_|napi_)[A-Za-z0-9_]+\s*\(", "raw native call (use a binding wrapper)"),
        ]
    return [f"{location}: {message}" for pattern, message in patterns if re.search(pattern, source)]


def main():
    root = Path(__file__).resolve().parents[1]
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
    ).decode().split("\0")
    errors = []
    manifests = 0
    for name in sorted(set(paths)):
        path = root / name
        if not path.is_file() or path == Path(__file__).resolve():
            continue
        if path.name == "Cargo.toml":
            manifests += 1
            errors.extend(manifest_errors(tomllib.loads(path.read_text()), name))
        elif path.suffix in {".rs", ".py", ".c", ".h", ".cpp"}:
            errors.extend(source_errors(path.read_text(), name, path.suffix == ".rs"))
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Native boundary passed: {manifests} manifests; no direct sys dependencies or runtime loaders.")


if __name__ == "__main__":
    main()
