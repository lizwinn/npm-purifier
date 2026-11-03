#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-relock: relocking a fixture reproduces its lockfiles byte for
# byte. `npm-purifier lock` runs on copies of the fixtures, from the
# network, and has to write package-lock.json and npm-purifier.lock.json
# as committed.
#
# For tests/fixtures/git, the run locks the git dependencies afresh. The
# entry for the repository the tests make (tests/git-repositories.nix)
# stays, because its URL resolves nowhere; the lock run reuses it.
#
# Usage: tests/conformance-relock.sh, from any directory, with Nix and the
# network.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export npm_config_cache="$work/.npm-cache"

nix build "$root#npm-purifier" --out-link "$work/command"
purifier="$work/command/bin/npm-purifier"

# relock <fixture directory>
relock() {
  local fixture="$root/tests/fixtures/$1" copy="$work/$1"
  mkdir -p "$copy"
  # The fixture's own files, without what an editor or agent left there,
  # one by one, as macOS's cp has no --parents.
  (cd "$fixture" && find . -type f -not -path './.claude/*') | while IFS= read -r file; do
    mkdir -p "$copy/${file%/*}"
    cp "$fixture/$file" "$copy/$file"
  done
  chmod -R u+w "$copy"
  (cd "$copy" && "$purifier" lock)
  diff -u "$fixture/package-lock.json" "$copy/package-lock.json"
  if [ -f "$fixture/npm-purifier.lock.json" ]; then
    diff -u "$fixture/npm-purifier.lock.json" "$copy/npm-purifier.lock.json"
  elif [ -f "$copy/npm-purifier.lock.json" ]; then
    echo "$1: the lock run wrote an npm-purifier.lock.json the fixture lacks" >&2
    exit 1
  fi
  echo "$1: relocked byte for byte"
}

# The git fixture keeps only the entry the run cannot make.
mkdir -p "$work/git"
nix run 'nixpkgs#jq' -- \
  '.git |= with_entries(select(.key | startswith("git+https://example.invalid/")))' \
  "$root/tests/fixtures/git/npm-purifier.lock.json" > "$work/git/npm-purifier.lock.json"

relock app
relock workspaces
relock git
relock paths/app
# `lock` keeps the old semver that `update` would move.
relock update
