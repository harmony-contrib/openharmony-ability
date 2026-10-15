#!/usr/bin/env sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

# ohpm-rs 0.3 installs a project at a time; --all covers its build-profile modules.
for package_dir in "$repo_root/native_ability" "$repo_root"/plugins/* "$repo_root/demo"; do
  if [ -f "$package_dir/oh-package.json5" ]; then
    ohpm-rs install --all --prefix "$package_dir"
  fi
done
