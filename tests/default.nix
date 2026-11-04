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
  # The flake's default package overlay, which adds the scope
  # `npm-purifier` with the builder and the commands.
  overlay,
  # The shared purifier library.
  purifier,
  # The library namespace of this flake, with readLock.
  npm-purifier,
}:
let
  inherit (pkgs) lib;

  withOverlay = pkgs.extend overlay;

  # Every fixture builds the way a consumer's package builds a project:
  # through the builder in the scope that the overlay adds.
  inherit (withOverlay.npm-purifier) buildNpmProject;

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

  # The lock in memory of tests/locks/<name>, which holds a
  # package-lock.json and no npm-purifier.lock.json.
  lockOf = name: npm-purifier.readLock { src = ./locks + "/${name}"; };
  host = pkgs.stdenv.hostPlatform.system;

  # The lock in memory of the project in `src`, with `lockFile` as its
  # npm-purifier.lock.json.
  gitLockOf = src: lockFile: npm-purifier.readLock { inherit src lockFile; };

  # The tarballs a lock gives one system.
  downloadsFor =
    system: lock: builtins.filter (entry: !(entry ? git)) (purifier.entriesFor system lock);

  # Whether the lock in memory refuses the lockfiles: it lists problems,
  # and the check of the purifier library fails evaluation with them.
  refused = lock: lock.problems != [ ] && fails (purifier.checkLock lock);
  gitPackageLock = ./locks/git/package-lock.json;

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
in
{
  composition-producer = workspaces.packages.greet-cli;
  npm-projection =
    pkgs.runCommand "npm-projection-check"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.python3
        ];
      }
      ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          python ${./npm-projection.py} ${workspaces.projections.npm} \
            ${workspaces.projections.npm.catalog} ${pkgs.nodejs}/bin \
        ${../nix/lib/npm-bindings.cjs}
          touch "$out"
      '';

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
      urls = system: map (d: d.url) (downloadsFor system (lockOf "platform-filter"));
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
    lockOf "git"
  )) "a lockfile with a git dependency evaluated without npm-purifier.lock.json";

  # The checks of the purifier contract that need neither the network nor
  # Nix itself. Each refused lockfile fails evaluation with a message that
  # names `npm-purifier lock`; tests/errors.sh checks the messages.

  # npm-purifier.lock.json made for another package-lock.json.
  conformance-stale = evalCheck "conformance-stale" (refused (
    gitLockOf ./locks/git ./fixtures/git/npm-purifier.lock.json
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
      gitLockOf ./fixtures/git tampered
    )) "npm-purifier.lock.json with a changed hash evaluated";

  # npm-purifier.lock.json without an entry for a git dependency.
  conformance-missing = evalCheck "conformance-missing" (refused (
    gitLockOf ./locks/git (purifierLockOf gitPackageLock "{}")
  )) "a git dependency without an entry in npm-purifier.lock.json evaluated";

  # npm-purifier.lock.json that is not JSON.
  conformance-malformed = evalCheck "conformance-malformed" (refused (
    gitLockOf ./locks/git (builtins.toFile "npm-purifier.lock.json" "not json")
  )) "an npm-purifier.lock.json that is not JSON evaluated";

  # The lock in memory of a fixture has the shape of the purifier
  # contract, with the fixture's packages as outputs.
  lock-in-memory =
    let
      lock = purifier.checkLock (gitLockOf ./fixtures/git ./fixtures/git/npm-purifier.lock.json);
    in
    evalCheck "lock-in-memory" (
      lock.purifier == "npm-purifier"
      && builtins.attrNames lock.outputs == [ "git-fixture" ]
      && builtins.length (builtins.filter (entry: entry ? git) lock.entries) == 4
    ) "the lock in memory of the git fixture is not its four git dependencies and one output";

  # A project whose source holds no npm-purifier.lock.json builds from one
  # kept outside it. It also builds when the flake replaces its
  # package-lock.json with one outside the source.
  conformance-external =
    let
      without =
        names:
        builtins.path {
          path = ./fixtures/git;
          name = "git-fixture-without-lockfiles";
          filter = path: _: !(lib.elem (baseNameOf path) names);
        };
      external = buildNpmProject {
        src = without [ "npm-purifier.lock.json" ];
        lockFile = ./fixtures/git/npm-purifier.lock.json;
        gitCheckouts.${cloneResolved} = repositories.checkout;
      };
      replaced = buildNpmProject {
        src = without [
          "npm-purifier.lock.json"
          "package-lock.json"
        ];
        lockFile = ./fixtures/git/npm-purifier.lock.json;
        packageLock = ./fixtures/git/package-lock.json;
        gitCheckouts.${cloneResolved} = repositories.checkout;
      };
    in
    pkgs.runCommand "conformance-external-check" { } ''
      for fixture in ${external.packages.git-fixture} ${replaced.packages.git-fixture}; do
        "$fixture/bin/git-fixture" | grep -qx 'clone: cloned, prepared (is-number says true), and from the submodule'
      done
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

  # A package written for callPackage, in an overlay of its own, takes the
  # scope by name and builds the same package as the fixture.
  consumer-package =
    let
      consumers = withOverlay.extend (
        final: prev: {
          hello-consumer = final.callPackage (
            { npm-purifier }: (npm-purifier.buildNpmProject { src = ./fixtures/app; }).packages.hello-npm
          ) { };
        }
      );
    in
    evalCheck "consumer-package" (
      consumers.hello-consumer.drvPath == (buildNpmProject { src = ./fixtures/app; })
      .packages.hello-npm.drvPath
    ) "a package that takes the npm-purifier scope by name built another derivation";

  # `buildNpmProject.override` replaces what the builder takes from the
  # scope and the package set: here the Node.js its packages run on.
  builder-override =
    let
      overridden = (buildNpmProject.override { nodejs = pkgs.nodejs-slim; }) { src = ./fixtures/app; };
    in
    evalCheck "builder-override" (
      map (input: input.name) overridden.packages.hello-npm.buildInputs == [ pkgs.nodejs-slim.name ]
    ) "buildNpmProject.override did not replace the Node.js of the packages";

  # `overrideScope` replaces what everything in the scope shares: here the
  # Node.js that the builder in the new scope takes.
  scope-override =
    let
      scoped = withOverlay.npm-purifier.overrideScope (_: _: { nodejs = pkgs.nodejs-slim; });
      built = scoped.buildNpmProject { src = ./fixtures/app; };
    in
    evalCheck "scope-override" (
      map (input: input.name) built.packages.hello-npm.buildInputs == [ pkgs.nodejs-slim.name ]
    ) "npm-purifier.overrideScope did not replace the Node.js of the builder";

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
  cache-path = evalCheck "cache-path" (
    map (d: d.path) (downloadsFor host (lockOf "cache-path")) == [
      "content-v2/sha512/53/f2/28e3ee0187efec90cbcd65cecff5e540b1ca425680a6a1b1e77bae878c92a929f314e4c3e668e9775bcdf366ad487f7929d3767e9621f25c91beb2f38b22"
    ]
  ) "the cache path of an integrity is not the one npm uses";

  # package-lock.json files the reader refuses, each with a message that
  # names the problem: one older than npm 7, a source that is neither a
  # tarball URL, a repository nor a path, and a tarball without an
  # integrity.
  old-lockfile = evalCheck "old-lockfile" (
    (lockOf "old").problems == [ ]
  ) "a lockfileVersion 1 lockfile was rejected";
  legacy-lock-tree =
    let
      lock = npm-purifier.readLock { src = ./fixtures/legacy-node; };
    in
    evalCheck "legacy-lock-tree" (
      lock.problems == [ ]
      && builtins.length lock.entries == 3
      && lock.outputs.legacy-npm-app.version == "1.0.0"
    ) "nested npm 6 dependencies or root manifest outputs were lost";
  unknown-source = evalCheck "unknown-source" (refused (
    lockOf "unknown-source"
  )) "a dependency from ftp evaluated";
  missing-integrity = evalCheck "missing-integrity" (refused (
    lockOf "missing-integrity"
  )) "a tarball without an integrity evaluated";

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
      ) null (gitLockOf ./fixtures/git ./fixtures/git/npm-purifier.lock.json).entries;
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
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  legacy-node = import ./legacy-node.nix { inherit pkgs buildNpmProject; };
  legacy-node-tools = import ./legacy-tools.nix {
    inherit pkgs;
    scope = withOverlay.npm-purifier;
  };
}
