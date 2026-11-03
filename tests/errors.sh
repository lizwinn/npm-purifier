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
      lock = lib.purifier.checkLock (lib.npm-purifier.readLock { src = $dir; });
    in builtins.deepSeq lock true
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

# purifierLock <name> <version> <packageLockSha256>: writes an
# npm-purifier.lock.json without entries, laid out and hashed as
# `npm-purifier lock` writes it.
purifierLock() {
  local file="$work/$1/npm-purifier.lock.json"
  printf '{\n  "version": %s,\n  "hash": "",\n  "packageLockSha256": "%s",\n  "git": {}\n}\n' "$2" "$3" > "$file"
  local hash
  hash="$(nix hash file --type sha256 --sri "$file")"
  edit "s|\"hash\": \"\"|\"hash\": \"$hash\"|" "$file"
}

# edit <sed script> <file>: edits the file in place, through a copy, as
# macOS's sed takes the word after `-i` for a backup suffix.
edit() {
  sed "$1" "$2" > "$2.new"
  mv "$2.new" "$2"
}

gitLock="{\"lockfileVersion\":3,\"packages\":{\"\":{\"name\":\"p\"},\"node_modules/a\":{\"resolved\":\"git+ssh://git@github.com/o/a.git#$sha\"}}}"

# A git dependency, and no npm-purifier.lock.json.
lockfile no-purifier-lock <<< "$gitLock"
expect no-purifier-lock 'run `npm-purifier lock`'

# npm-purifier.lock.json made for another package-lock.json: the developer
# edited package-lock.json without the wrapper.
lockfile stale <<< "$gitLock"
purifierLock stale 3 0000
expect stale 'was made for another package-lock.json; run `npm-purifier lock`'

# npm-purifier.lock.json without the git dependency.
lockfile missing-entry <<< "$gitLock"
purifierLock missing-entry 3 "$(sha256sum "$work/missing-entry/package-lock.json" | cut -d' ' -f1)"
expect missing-entry 'has no entry for'

# npm-purifier.lock.json changed by hand after the lock run wrote it.
lockfile tampered <<< "$gitLock"
purifierLock tampered 3 "$(sha256sum "$work/tampered/package-lock.json" | cut -d' ' -f1)"
edit 's|"git": {}|"git": {"x": {}}|' "$work/tampered/npm-purifier.lock.json"
expect tampered 'was changed after `npm-purifier lock` wrote it'

# npm-purifier.lock.json of an older format.
lockfile old-format <<< "$gitLock"
purifierLock old-format 2 "$(sha256sum "$work/old-format/package-lock.json" | cut -d' ' -f1)"
expect old-format 'is not of format version 3; run `npm-purifier lock`'

# Unknown native lock formats need a version-specific reader.
lockfile old <<< '{"lockfileVersion":99,"packages":{}}'
expect old 'unsupported lockfileVersion 99'

# A tarball without an integrity.
lockfile no-integrity <<< '{"lockfileVersion":3,"packages":{"node_modules/a":{"resolved":"https://registry.npmjs.org/a/-/a-1.0.0.tgz"}}}'
expect no-integrity 'run `npm-purifier lock` to record one'

# A tarball without a URL, as some lockfiles leave it.
lockfile no-resolved <<< '{"lockfileVersion":3,"packages":{"node_modules/url-join":{"version":"4.0.1"}}}'
expect no-resolved 'node_modules/url-join has no resolved URL'

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

# A lockfile that starts as JSON and does not parse.
lockfile truncated <<< '{"lockfileVersion": 3, "packages": {'
expect truncated 'package-lock.json, which is not valid JSON; run `npm install`'

exit "$status"
