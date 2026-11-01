#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Checks the lock run (`npm nix-lock`): it locks the git dependencies of
# tests/fixtures/git afresh, from the network, and has to write the
# committed npm-purifier.lock.json again. The entry for the repository the
# tests make (tests/git-repositories.nix) stays, because its URL resolves
# nowhere; the lock run reuses it.
#
# Usage: tests/lock-run.sh, from any directory, with Nix and the network.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp -r "$root/tests/fixtures/git/." "$work"
chmod -R u+w "$work"
nix run 'nixpkgs#jq' -- \
  '.git |= with_entries(select(.key | startswith("git+https://example.invalid/")))' \
  "$root/tests/fixtures/git/npm-purifier.lock.json" > "$work/npm-purifier.lock.json"

cd "$work"
npm_config_cache="$work/.npm-cache" nix run "$root#npm" -- nix-lock
diff -u "$root/tests/fixtures/git/npm-purifier.lock.json" "$work/npm-purifier.lock.json"
echo "lock run: npm-purifier.lock.json matches"
