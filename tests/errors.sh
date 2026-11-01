#!/usr/bin/env bash
# The expected messages quote commands in backticks, which stay literal.
# shellcheck disable=SC2016
# SPDX-License-Identifier: MIT
#
# Checks the messages of the mistakes a developer makes: each lockfile
# below is wrong in one way, and evaluating it has to fail with a message
# that says what is wrong and which command fixes it.
#
# Usage: tests/errors.sh, from any directory, with Nix.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sha=98e8ff1da1a89f93d1397a24d7413ed15421c139
status=0

# expect <name> <expected text>: evaluates the lockfiles in $work/<name>
# and checks that the evaluation fails with the expected text.
expect() {
  local dir="$work/$1"
  local out
  if out="$(nix eval --impure --expr "
    let
      # The library of this flake, which holds the purifier library.
      lib = (builtins.getFlake \"git+file://$root\").lib;
      lock = import $root/nix/lib/lock.nix {
        inherit lib;
        inherit (lib) purifier;
        system = builtins.currentSystem;
        lockFile = $dir/package-lock.json;
      };
    in builtins.deepSeq [ lock.downloads lock.git lock.packages ] true
  " 2>&1)"; then
    echo "$1: evaluated, but should have failed" >&2
    status=1
  elif ! grep -qF -- "$2" <<< "$out"; then
    echo "$1: the message lacks \"$2\":" >&2
    echo "$out" >&2
    status=1
  else
    echo "$1: ok"
  fi
}

lockfile() {
  mkdir -p "$work/$1"
  cat > "$work/$1/package-lock.json"
}

gitLock="{\"lockfileVersion\":3,\"packages\":{\"\":{\"name\":\"p\"},\"node_modules/a\":{\"resolved\":\"git+ssh://git@github.com/o/a.git#$sha\"}}}"

# A git dependency, and no npm-purifier.lock.json.
lockfile no-purifier-lock <<< "$gitLock"
expect no-purifier-lock 'run `npm nix-lock`'

# npm-purifier.lock.json made for another package-lock.json: the developer
# edited package-lock.json without the wrapper.
lockfile stale <<< "$gitLock"
echo '{"version":1,"packageLockSha256":"0000","git":{}}' > "$work/stale/npm-purifier.lock.json"
expect stale 'was made for another package-lock.json; run `npm nix-lock`'

# npm-purifier.lock.json without the git dependency.
lockfile missing-entry <<< "$gitLock"
hash="$(sha256sum "$work/missing-entry/package-lock.json" | cut -d' ' -f1)"
echo "{\"version\":1,\"packageLockSha256\":\"$hash\",\"git\":{}}" > "$work/missing-entry/npm-purifier.lock.json"
expect missing-entry 'has no entry for'

# A lockfile from npm 6.
lockfile old <<< '{"lockfileVersion":1,"dependencies":{}}'
expect old 'run `npm install` with npm 7 or newer'

# A tarball without an integrity.
lockfile no-integrity <<< '{"lockfileVersion":3,"packages":{"node_modules/a":{"resolved":"https://registry.npmjs.org/a/-/a-1.0.0.tgz"}}}'
expect no-integrity 'run `npm install` to record one'

# A source npm-purifier does not know.
lockfile unknown <<< '{"lockfileVersion":3,"packages":{"node_modules/a":{"resolved":"ftp://example.invalid/a.tgz"}}}'
expect unknown 'neither a tarball URL, a git repository nor a path'

# A lockfile left with a merge conflict.
lockfile conflict << 'EOF'
{
<<<<<<< HEAD
  "lockfileVersion": 3,
=======
  "lockfileVersion": 2,
>>>>>>> other
  "packages": {}
}
EOF
expect conflict 'package-lock.json has merge conflict markers; run `npm install`'

# A lockfile that is not JSON at all.
lockfile malformed <<< 'not json'
expect malformed 'package-lock.json is not a JSON lockfile; run `npm install`'

exit "$status"
