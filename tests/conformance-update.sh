#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-update: `npm-purifier update` moves a pinned dependency, and
# both lockfiles then pass the stale check. tests/fixtures/update locks
# semver 7.0.0 under the range ^7.0.0, and has a git dependency, so its
# npm-purifier.lock.json names the package-lock.json it was made for. The
# update has to move semver, and readLock has to find no problem in the
# lockfiles the update leaves.
#
# Usage: tests/conformance-update.sh, from any directory, with Nix and the
# network.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export npm_config_cache="$work/.npm-cache"

nix build "$root#npm-purifier" --out-link "$work/command"

fixture="$root/tests/fixtures/update"
mkdir "$work/update"
cp "$fixture/package.json" "$fixture/package-lock.json" "$fixture/npm-purifier.lock.json" "$work/update"
chmod u+w "$work/update"/*
(cd "$work/update" && "$work/command/bin/npm-purifier" update)

version="$(nix run 'nixpkgs#jq' -- -r '.packages["node_modules/semver"].version' "$work/update/package-lock.json")"
if [ "$version" = 7.0.0 ]; then
  echo "conformance-update: semver stayed at 7.0.0" >&2
  exit 1
fi
if cmp -s "$fixture/npm-purifier.lock.json" "$work/update/npm-purifier.lock.json"; then
  echo "conformance-update: npm-purifier.lock.json still names the old package-lock.json" >&2
  exit 1
fi

problems="$(nix eval --impure --json --expr "
  (builtins.getFlake \"git+file://$root\").lib.npm-purifier.readLock { src = $work/update; }
" --apply 'lock: lock.problems')"
if [ "$problems" != "[]" ]; then
  echo "conformance-update: the updated lockfiles have problems: $problems" >&2
  exit 1
fi

echo "conformance-update: semver moved from 7.0.0 to $version, and both lockfiles pass the stale check"
