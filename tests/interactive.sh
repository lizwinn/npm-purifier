#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Checks the `npm` wrapper on copies of the fixtures. The registry is an
# address nothing listens on, so a command that reached for the network
# would fail: `npm ci`, the build script and the tests run on the locked
# tarballs alone. `npm nix-publish --dry-run` then builds the package with
# Nix and hands the tarball to `npm publish`.
#
# Usage: tests/interactive.sh, from any directory, with Nix.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

nix build "$root#npm" --out-link "$work/wrapper"
npm="$work/wrapper/bin/npm"
export XDG_CACHE_HOME="$work/xdg"
# The cache of the commands the wrapper passes to npm unchanged.
export npm_config_cache="$work/npm-cache"
export npm_config_registry=http://127.0.0.1:9/

cp -r "$root/tests/fixtures/app" "$work/app"
chmod -R u+w "$work/app"
(
  cd "$work/app"
  "$npm" ci
  "$npm" run build
  "$npm" test
  "$npm" nix-publish --dry-run 2>&1 | grep 'name: *hello-npm'
)

cp -r "$root/tests/fixtures/paths" "$work/paths"
chmod -R u+w "$work/paths"
(
  cd "$work/paths/app"
  "$npm" ci
  "$npm" exec -c 'node cli.js' | grep -x 'shared: from the shared directory beside the project'
)

echo "interactive: the wrapper works offline"
