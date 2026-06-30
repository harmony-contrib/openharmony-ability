#!/usr/bin/env sh
set -eu

before="$(mktemp)"
after="$(mktemp)"
trap 'rm -f "$before" "$after"' EXIT

git diff --binary > "$before"
pnpm format
git diff --binary > "$after"

if ! cmp -s "$before" "$after"; then
  echo "Formatting changed files. Review and stage the updated files before committing."
  git diff --stat
  exit 1
fi
