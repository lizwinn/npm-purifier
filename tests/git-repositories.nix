# SPDX-License-Identifier: MIT
#
# Two git repositories the tests make themselves, for a git dependency
# that npm clones rather than downloading as an archive: `clone` is an npm
# package whose prepare script needs a dev dependency, and whose submodule
# vendor/sub is the repository `sub`. The commits have fixed authors and
# dates, so their IDs are always the same, and the fixture `git` locks
# them by those IDs.
#
# The fixture names the repositories by URLs under example.invalid, which
# resolve nowhere: its build takes `clone` as a checkout (gitCheckouts),
# and maps the submodule URL to vendor/sub inside it, as it would for a
# fetched repository.
{ runCommand, git }:
let
  commit = ''
    export HOME="$TMPDIR"
    export GIT_AUTHOR_NAME=npm-purifier GIT_AUTHOR_EMAIL=tests@npm-purifier.invalid
    export GIT_COMMITTER_NAME=npm-purifier GIT_COMMITTER_EMAIL=tests@npm-purifier.invalid
    export GIT_AUTHOR_DATE=2026-11-01T00:00:00Z GIT_COMMITTER_DATE=2026-11-01T00:00:00Z
    # The store belongs to another user than the build.
    git config --global safe.directory '*'
    git init -q -b main
  '';

  sub = runCommand "npm-purifier-test-sub" { nativeBuildInputs = [ git ]; } ''
    mkdir "$out"
    cd "$out"
    ${commit}
    echo 'module.exports = "from the submodule";' > index.js
    git add index.js
    git commit -q -m "Add the submodule's module"
  '';

  clone = runCommand "npm-purifier-test-clone" { nativeBuildInputs = [ git ]; } ''
    mkdir "$out"
    cd "$out"
    ${commit}
    cat > package.json <<'EOF'
    {
      "name": "npm-purifier-clone-fixture",
      "version": "1.0.0",
      "license": "MIT",
      "main": "dist/index.js",
      "files": ["dist", "vendor"],
      "scripts": { "prepare": "node build.js" },
      "devDependencies": { "is-number": "7.0.0" }
    }
    EOF
    cat > build.js <<'EOF'
    const fs = require("fs");
    const isNumber = require("is-number");
    fs.mkdirSync("dist", { recursive: true });
    fs.writeFileSync(
      "dist/index.js",
      `module.exports = "cloned, prepared (is-number says ${"$"}{isNumber(7)}), and " + require("../vendor/sub");\n`,
    );
    EOF
    printf '[submodule "vendor/sub"]\n\tpath = vendor/sub\n\turl = https://example.invalid/npm-purifier-sub.git\n' > .gitmodules
    git update-index --add --cacheinfo "160000,$(git -C ${sub} rev-parse HEAD),vendor/sub"
    git add package.json build.js .gitmodules
    git commit -q -m "Add the package"
    # The submodule checked out, as fetchgit leaves a repository it fetches
    # with its submodules. The clone copies the objects: hard links to the
    # store's files would put files of the store's owner in this output.
    git clone -q --no-hardlinks ${sub} vendor/sub
  '';
in
{
  inherit sub clone;
  # The plain checkout of `clone` with its submodule, as fetchgit makes it
  # for the build.
  checkout = runCommand "npm-purifier-test-checkout" { } ''
    cp -r ${clone} "$out"
    chmod -R u+w "$out"
    rm -rf "$out/.git" "$out/vendor/sub/.git"
  '';
}
