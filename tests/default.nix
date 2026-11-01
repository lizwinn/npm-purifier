# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked tarballs and git checkouts.
# The checks of the purifier contract that need the network or Nix itself
# run in CI as jobs of the same name: conformance-relock
# (tests/conformance-relock.sh), conformance-rebuild
# (tests/conformance-rebuild.sh), conformance-offline
# (tests/conformance-offline.sh) and conformance-update
# (tests/conformance-update.sh).
{
  pkgs,
  # The flake's default package overlay, which adds the commands.
  overlay,
  # The shared purifier library.
  purifier,
  # The library namespace of this flake, with buildNpmProject.
  npm-purifier,
}:
let
  inherit (pkgs) lib;

  withOverlay = pkgs.extend overlay;

  # Every fixture builds the way a consumer's flake builds a project:
  # through the builder of this flake's library, with a package set.
  buildNpmProject = args: npm-purifier.buildNpmProject ({ inherit pkgs; } // args);

  # One package with a build script, a test script, a command, a
  # dependency and a dev dependency.
  app = buildNpmProject {
    src = ./fixtures/app;
    doCheck = true;
  };

  # A root that declares workspaces, a library workspace and a
  # command-line workspace that depends on the library and on esbuild,
  # whose native binary comes from a per-platform optional package.
  workspaces = buildNpmProject { src = ./fixtures/workspaces; };

  # Every kind of git dependency: a GitHub archive, a GitHub archive npm
  # prepares, a Codeberg repository npm clones, and a cloned repository
  # with a submodule that npm prepares. The last one is a repository these
  # tests make (tests/git-repositories.nix), which the build takes as a
  # checkout.
  repositories = pkgs.callPackage ./git-repositories.nix { };
  cloneResolved = "git+https://example.invalid/npm-purifier-clone.git#c2eaed048fb06b92697c038ecaf17236a1a363fa";
  git = buildNpmProject {
    src = ./fixtures/git;
    gitCheckouts.${cloneResolved} = repositories.checkout;
  };

  # A project in a directory of a larger tree: it depends on a directory
  # beside it, on a tarball inside it and on a tarball URL.
  paths = buildNpmProject {
    src = ./fixtures/paths;
    projectDir = "app";
  };

  # Real projects, pinned (real-world.nix).
  real = import ./real-world.nix { inherit buildNpmProject; };

  # The lock in memory of a package-lock.json written inline. The app
  # fixture has no npm-purifier.lock.json.
  lockOf =
    lock:
    npm-purifier.readLock {
      src = ./fixtures/app;
      packageLock = builtins.toFile "package-lock.json" (builtins.toJSON lock);
    };
  host = pkgs.stdenv.hostPlatform.system;

  # The lock in memory of a package-lock.json and an npm-purifier.lock.json.
  gitLockOf =
    packageLock: lockFile:
    npm-purifier.readLock {
      src = ./fixtures/git;
      inherit packageLock lockFile;
    };

  # The tarballs a lock gives one system.
  downloadsFor =
    system: lock: builtins.filter (entry: !(entry ? git)) (purifier.entriesFor system lock);

  # Whether the lock in memory refuses the lockfiles: it lists problems,
  # and the check of the purifier library fails evaluation with them.
  refused = lock: lock.problems != [ ] && fails (purifier.checkLock lock);
  gitPackageLock = builtins.toFile "package-lock.json" (builtins.toJSON gitLock);

  # An npm-purifier.lock.json for a package-lock.json, with `git` (JSON
  # text) as its entries, laid out and hashed as `npm-purifier lock` writes
  # it: the SRI hash of the text with the hash left empty.
  purifierLockOf =
    packageLock: git:
    let
      blank = ''
        {
          "version": 3,
          "hash": "",
          "packageLockSha256": "${builtins.hashFile "sha256" packageLock}",
          "git": ${git}
        }
      '';
      hash = builtins.convertHash {
        hash = builtins.hashString "sha256" blank;
        hashAlgo = "sha256";
        toHashFormat = "sri";
      };
    in
    builtins.toFile "npm-purifier.lock.json" (
      builtins.replaceStrings [ ''"hash": ""'' ] [ ''"hash": "${hash}"'' ] blank
    );

  # Whether evaluating `value` deeply fails.
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;

  # A check of evaluation passes when `assertion` holds; it fails with
  # `message` otherwise.
  evalCheck =
    name: assertion: message:
    if assertion then
      pkgs.runCommand name { } "touch $out"
    else
      throw "npm-purifier check ${name}: ${message}";

  gitLock = {
    lockfileVersion = 3;
    packages = {
      "" = {
        name = "p";
      };
      "node_modules/is-number" = {
        resolved = "git+ssh://git@github.com/jonschlinkert/is-number.git#98e8ff1da1a89f93d1397a24d7413ed15421c139";
      };
    };
  };
in
{
  # The package's command prints what its build script wrote, and its
  # dev dependency stays out of the installed package.
  app =
    pkgs.runCommand "app-check"
      {
        nativeBuildInputs = [ app.packages.hello-npm ];
      }
      ''
        hello-npm | grep -q 'hello-npm: built by the build script'
        if [ -e ${app.packages.hello-npm}/lib/node_modules/is-odd ]; then
          echo "the dev dependency is-odd is installed" >&2
          exit 1
        fi
        tar -xzOf ${app.packages.hello-npm.tarball}/package.tgz package/dist/message.js \
          | grep -q 'built by the build script'
        touch $out
      '';

  # The command-line workspace finds the library workspace and the native
  # binary of esbuild; the library installs on its own. The workspace's
  # build script ran the esbuild command, a Node.js script whose first line
  # is `#!/usr/bin/env node`, in the sandbox.
  workspaces =
    pkgs.runCommand "workspaces-check"
      {
        nativeBuildInputs = [
          workspaces.packages.greet-cli
          pkgs.nodejs
        ];
      }
      ''
        greet 42 | grep -qx 'hello, number 42 (esbuild: let n = 1;)'
        grep -qx 0.25.0 ${workspaces.packages.greet-cli}/lib/node_modules/greet-cli/esbuild-version.txt
        NODE_PATH=${
          workspaces.packages."@fixture/greeting"
        }/lib/node_modules node -e 'console.log(require("@fixture/greeting")("you"))' \
          | grep -qx 'hello, you'
        touch $out
      '';

  # A workspace root without commands is no package of its own.
  workspaces-root = evalCheck "workspaces-root" (
    !(workspaces.packages ? workspaces-fixture)
  ) "the workspace root is a package";

  # Every git dependency installs offline, the prepared ones as their
  # prepare scripts built them, and the cloned one with its submodule.
  git =
    pkgs.runCommand "git-check"
      {
        nativeBuildInputs = [ git.packages.git-fixture ];
      }
      ''
        git-fixture > out
        grep -qx 'is-number: true' out
        grep -qx 'prepared: prepared (is-number says true)' out
        grep -qx 'clone: cloned, prepared (is-number says true), and from the submodule' out
        grep -qx 'remark-iptc-caption: installed' out
        touch $out
      '';

  # The test repository has the commit the fixture locks.
  git-repository =
    pkgs.runCommand "git-repository-check"
      {
        nativeBuildInputs = [ pkgs.git ];
      }
      ''
        export HOME="$TMPDIR"
        git config --global safe.directory '*'
        test "$(git -C ${repositories.clone} rev-parse HEAD)" = c2eaed048fb06b92697c038ecaf17236a1a363fa
        touch $out
      '';

  # The directory beside the project, the tarball inside it and the
  # tarball URL all install.
  paths =
    pkgs.runCommand "paths-check"
      {
        nativeBuildInputs = [ paths.packages.paths-fixture ];
      }
      ''
        paths-fixture > out
        grep -qx 'shared: from the shared directory beside the project' out
        grep -qx 'vendored: from a tarball inside the project' out
        grep -qx 'is-odd: true' out
        touch $out
      '';

  # Only the optional packages for the platform are fetched.
  platform-filter =
    let
      lock = {
        lockfileVersion = 3;
        packages = {
          "" = {
            name = "p";
          };
          "node_modules/@esbuild/linux-x64" = {
            resolved = "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.25.0.tgz";
            integrity = "sha512-9yl91rHw/cpwMCNytUDxwj2XjFpxML0y9HAOH9pNVQDpQrBxHy01Dx+vaMu0N1CKa/RzBD2hB4u//nfc+Sd3Cw==";
            optional = true;
            os = [ "linux" ];
            cpu = [ "x64" ];
          };
          "node_modules/@esbuild/linux-arm64" = {
            resolved = "https://registry.npmjs.org/@esbuild/linux-arm64/-/linux-arm64-0.25.0.tgz";
            integrity = "sha512-9QAQjTWNDM/Vk2bgBl17yWuZxZNQIF0OUUuPZRKoDtqF2k4EtYbpyiG5/Dk7nqeK6kIJWPYldkOcBqjXjrUlmg==";
            optional = true;
            os = [ "linux" ];
            cpu = [ "arm64" ];
          };
        };
      };
      urls = system: map (d: d.url) (downloadsFor system (lockOf lock));
    in
    evalCheck "platform-filter" (
      urls "x86_64-linux" == [
        "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.25.0.tgz"
      ]
      &&
        urls "aarch64-linux" == [
          "https://registry.npmjs.org/@esbuild/linux-arm64/-/linux-arm64-0.25.0.tgz"
        ]
    ) "the downloads for x86_64-linux and aarch64-linux are not the matching esbuild package";

  # A lockfile with git dependencies needs npm-purifier.lock.json, and one
  # made for this package-lock.json.
  git-without-purifier-lock = evalCheck "git-without-purifier-lock" (refused (
    lockOf gitLock
  )) "a lockfile with a git dependency evaluated without npm-purifier.lock.json";

  # The checks of the purifier contract that need neither the network nor
  # Nix itself. Each refused lockfile fails evaluation with a message that
  # names `npm-purifier lock`; tests/errors.sh checks the messages.

  # npm-purifier.lock.json made for another package-lock.json.
  conformance-stale = evalCheck "conformance-stale" (refused (
    gitLockOf gitPackageLock ./fixtures/git/npm-purifier.lock.json
  )) "npm-purifier.lock.json of another package-lock.json evaluated";

  # npm-purifier.lock.json with a changed hash in it.
  conformance-tampered =
    let
      tampered = builtins.toFile "npm-purifier.lock.json" (
        builtins.replaceStrings
          [ "sha256-CumxwVYdwi+5XAhb2esa2or74nV49zo+O9dHW6GPPkI=" ]
          [ "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ]
          (builtins.readFile ./fixtures/git/npm-purifier.lock.json)
      );
    in
    evalCheck "conformance-tampered" (refused (
      gitLockOf ./fixtures/git/package-lock.json tampered
    )) "npm-purifier.lock.json with a changed hash evaluated";

  # npm-purifier.lock.json without an entry for a git dependency.
  conformance-missing = evalCheck "conformance-missing" (refused (
    gitLockOf gitPackageLock (purifierLockOf gitPackageLock "{}")
  )) "a git dependency without an entry in npm-purifier.lock.json evaluated";

  # npm-purifier.lock.json that is not JSON.
  conformance-malformed = evalCheck "conformance-malformed" (refused (
    gitLockOf gitPackageLock (builtins.toFile "npm-purifier.lock.json" "not json")
  )) "an npm-purifier.lock.json that is not JSON evaluated";

  # The lock in memory of a fixture has the shape of the purifier
  # contract, with the fixture's packages as outputs.
  lock-in-memory =
    let
      lock = purifier.checkLock (
        gitLockOf ./fixtures/git/package-lock.json ./fixtures/git/npm-purifier.lock.json
      );
    in
    evalCheck "lock-in-memory" (
      lock.purifier == "npm-purifier"
      && builtins.attrNames lock.outputs == [ "git-fixture" ]
      && builtins.length (builtins.filter (entry: entry ? git) lock.entries) == 4
    ) "the lock in memory of the git fixture is not its four git dependencies and one output";

  # A project whose source holds no npm-purifier.lock.json builds from one
  # kept outside it.
  conformance-external =
    let
      external = buildNpmProject {
        src = builtins.path {
          path = ./fixtures/git;
          name = "git-fixture-without-purifier-lock";
          filter = path: _: baseNameOf path != "npm-purifier.lock.json";
        };
        lockFile = ./fixtures/git/npm-purifier.lock.json;
        gitCheckouts.${cloneResolved} = repositories.checkout;
      };
    in
    pkgs.runCommand "conformance-external-check"
      {
        nativeBuildInputs = [ external.packages.git-fixture ];
      }
      ''
        git-fixture | grep -qx 'clone: cloned, prepared (is-number says true), and from the submodule'
        touch $out
      '';

  # The tarball Nix builds is one `npm publish` takes.
  publish =
    pkgs.runCommand "publish-check"
      {
        nativeBuildInputs = [ pkgs.nodejs ];
      }
      ''
        export HOME="$TMPDIR" npm_config_cache="$TMPDIR/cache" npm_config_offline=true
        npm publish --dry-run ${app.packages.hello-npm.tarball}/package.tgz 2> log
        grep -q 'name: *hello-npm' log
        grep -q 'dist/message.js' log
        touch $out
      '';

  # `npm-purifier publish` builds the tarball the builder builds, also for
  # a project in a directory of a larger tree.
  publish-build =
    let
      published = import ../nix/lib/project.nix {
        inherit pkgs;
        lib = lib // {
          inherit npm-purifier;
        };
        packageLock = ./fixtures/paths/app/package-lock.json;
      };
    in
    evalCheck "publish-build" (
      published.packages.paths-fixture.tarball.outPath == paths.packages.paths-fixture.tarball.outPath
    ) "npm-purifier publish builds another tarball than buildNpmProject";

  # What the wrapper builds for a project (`interactive`) holds the cache
  # the sandboxed build of the project uses, and the environment setup.
  interactive = pkgs.runCommand "interactive-check" { } ''
    test "$(readlink ${app.interactive}/cache)" = ${app.cache}
    test "$(readlink ${git.interactive}/cache)" = ${git.cache}
    # The URLs of the Codeberg repository, the test repository and its
    # submodule, local clones of submodules, and the store's owner.
    grep -q GIT_CONFIG_COUNT=5 ${git.interactive}/environment
    touch $out
  '';

  # The commands build.
  npm = withOverlay.npm-purifier.npm;
  npm-purifier-command = withOverlay.npm-purifier.npm-purifier;

  # commander.js builds, and its tests and type checks pass; the package
  # depends on them.
  real-commander = real.commander.packages.commander;

  # http-server builds from its completed lockfile, its tests pass, and its
  # command runs.
  real-http-server =
    pkgs.runCommand "real-http-server-check"
      {
        nativeBuildInputs = [ real.httpServer.packages.http-server ];
      }
      ''
        http-server --version | grep -qx v14.1.2
        touch $out
      '';

  # The unit tests of the lock run (pkgs/npm-purifier/lock.test.js).
  lock-run-units =
    pkgs.runCommand "lock-run-units"
      {
        nativeBuildInputs = [ pkgs.nodejs ];
        NPM_PURIFIER_NPM_MODULES = "${pkgs.nodejs}/lib/node_modules/npm/node_modules";
      }
      ''
        cp ${../pkgs/npm-purifier/lock.js} lock.js
        cp ${../pkgs/npm-purifier/lock.test.js} lock.test.js
        node --test lock.test.js
        touch $out
      '';

  # An integrity gives the path npm itself puts the tarball at in its
  # cache; the expected path is one npm wrote.
  cache-path =
    let
      lock = {
        lockfileVersion = 3;
        packages = {
          "" = {
            name = "p";
          };
          "node_modules/is-number" = {
            resolved = "https://example.invalid/is-number.tgz";
            integrity = "sha512-U/Io4+4Bh+/skMvNZc7P9eVAscpCVoCmobHne66HjJKpKfMU5MPmaOl3W83zZq1If3kp03Z+liHyXJG+svOLIg==";
          };
        };
      };
    in
    evalCheck "cache-path" (
      map (d: d.path) (downloadsFor host (lockOf lock)) == [
        "content-v2/sha512/53/f2/28e3ee0187efec90cbcd65cecff5e540b1ca425680a6a1b1e77bae878c92a929f314e4c3e668e9775bcdf366ad487f7929d3767e9621f25c91beb2f38b22"
      ]
    ) "the cache path of an integrity is not the one npm uses";

  # package-lock.json files the reader refuses, each with a message that
  # names the problem: one older than npm 7, a source that is neither a
  # tarball URL, a repository nor a path, and a tarball without an
  # integrity.
  old-lockfile = evalCheck "old-lockfile" (refused (lockOf {
    lockfileVersion = 1;
    dependencies = { };
  })) "a lockfileVersion 1 lockfile evaluated";
  unknown-source = evalCheck "unknown-source" (refused (lockOf {
    lockfileVersion = 3;
    packages."node_modules/a".resolved = "ftp://example.invalid/a.tgz";
  })) "a dependency from ftp evaluated";
  missing-integrity = evalCheck "missing-integrity" (refused (lockOf {
    lockfileVersion = 3;
    packages."node_modules/a".resolved = "https://registry.npmjs.org/a/-/a-1.0.0.tgz";
  })) "a tarball without an integrity evaluated";

  # A tarball whose bytes do not match its integrity fails the install:
  # here the fetcher hands npm another file.
  tampered-tarball =
    let
      tampered = buildNpmProject {
        src = ./fixtures/app;
        fetchers.fetchurl = { name, ... }: pkgs.writeText name "not the tarball";
      };
    in
    pkgs.runCommand "tampered-tarball-check" { } ''
      grep -q 'seems to be corrupted' ${pkgs.testers.testBuildFailure tampered.release}/testBuildFailure.log
      touch $out
    '';

  # A submodule whose recorded commit object is not its locked commit fails
  # the build of its repository, with a message that names the commit.
  tampered-commit =
    let
      clone = lib.findFirst (
        entry: (entry.resolved or null) == cloneResolved
      ) null (gitLockOf ./fixtures/git/package-lock.json ./fixtures/git/npm-purifier.lock.json).entries;
      tampered = clone // {
        submodules = map (s: s // { rev = "0000000000000000000000000000000000000000"; }) clone.submodules;
      };
      made =
        (pkgs.callPackage ../nix/lib/git.nix {
          inherit purifier;
          git = {
            ${cloneResolved} = tampered;
          };
          checkouts.${cloneResolved} = repositories.checkout;
        }).repositories.${cloneResolved};
    in
    pkgs.runCommand "tampered-commit-check" { } ''
      grep -q 'is not commit 0000000000000000000000000000000000000000' \
        ${pkgs.testers.testBuildFailure made}/testBuildFailure.log
      touch $out
    '';
}
