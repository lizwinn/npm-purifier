#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-offline: after `npm-purifier prefetch`, the everyday loop of
# a fixture works with no network. The registry is an address nothing
# listens on, so a command that reached for the network would fail:
# `npm ci`, the build script and the tests run on what the prefetch
# keeps, and `npm-purifier publish --dry-run` hands the tarball Nix built
# to `npm publish`.
#
# Usage: tests/conformance-offline.sh, from any directory, with Nix.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

nix build "$root#npm" --out-link "$work/npm"
nix build "$root#npm-purifier" --out-link "$work/command"
npm="$work/npm/bin/npm"
purifier="$work/command/bin/npm-purifier"
# The cache of the commands the wrapper passes to npm unchanged.
export npm_config_cache="$work/npm-cache"

cp -r "$root/tests/fixtures/app" "$work/app"
cp -r "$root/tests/fixtures/paths" "$work/paths"
chmod -R u+w "$work/app" "$work/paths"

(cd "$work/app" && "$purifier" prefetch)
(cd "$work/paths/app" && "$purifier" prefetch)
test -L "$work/app/.npm-purifier/dependencies"

export npm_config_registry=http://127.0.0.1:9/
(
  cd "$work/app"
  "$npm" ci
  "$npm" run build
  "$npm" test
  "$purifier" publish --dry-run 2>&1 | grep 'name: *hello-npm'
)
(
  cd "$work/paths/app"
  "$npm" ci
  "$npm" exec -c 'node cli.js' | grep -x 'shared: from the shared directory beside the project'
)

echo "conformance-offline: the everyday loop works offline after the prefetch"
