# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked tarballs and git checkouts.
# tests/lock-run.sh and tests/interactive.sh check the lock run and the
# `npm` wrapper, which need the network and Nix itself.
{
  pkgs,
  # The flake's default package overlay, which adds buildNpmProject.
  overlay,
}:
let
  inherit (pkgs) lib;

  # Every fixture builds the way a consumer's package does: through
  # buildNpmProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildNpmProject;

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

  # Evaluates the lockfile reader on a lockfile written inline.
  readLock =
    platform: lock:
    import ../nix/lib/lock.nix {
      inherit lib platform;
      lockFile = builtins.toFile "package-lock.json" (builtins.toJSON lock);
    };
  host = pkgs.stdenv.hostPlatform;

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
  # binary of esbuild; the library installs on its own.
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
      urls = platform: map (d: d.url) (readLock platform lock).downloads;
    in
    evalCheck "platform-filter" (
      urls (lib.systems.elaborate "x86_64-linux") == [
        "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.25.0.tgz"
      ]
      &&
        urls (lib.systems.elaborate "aarch64-linux") == [
          "https://registry.npmjs.org/@esbuild/linux-arm64/-/linux-arm64-0.25.0.tgz"
        ]
    ) "the downloads for x86_64-linux and aarch64-linux are not the matching esbuild package";

  # A lockfile with git dependencies needs npm-purifier.lock.json, and one
  # made for this package-lock.json.
  git-without-purifier-lock = evalCheck "git-without-purifier-lock" (fails (readLock host gitLock)
    .git) "a lockfile with a git dependency evaluated without npm-purifier.lock.json";
  stale-purifier-lock = evalCheck "stale-purifier-lock" (fails
    (import ../nix/lib/lock.nix {
      inherit lib;
      platform = host;
      lockFile = builtins.toFile "package-lock.json" (builtins.toJSON gitLock);
      purifierLockFile = ./fixtures/git/npm-purifier.lock.json;
    }).git
  ) "npm-purifier.lock.json of another package-lock.json evaluated";

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

  # `npm nix-publish` builds the tarball the builder builds, also for a
  # project in a directory of a larger tree.
  publish-build =
    let
      published = import ../nix/lib/publish.nix {
        pkgs = withOverlay;
        lockFile = ./fixtures/paths/app/package-lock.json;
      };
    in
    evalCheck "publish-build" (
      published.packages.paths-fixture.tarball.outPath == paths.packages.paths-fixture.tarball.outPath
    ) "npm nix-publish builds another tarball than buildNpmProject";

  # The wrapper evaluates nix/lib/interactive.nix for a project; the cache
  # it builds is the one the sandboxed build of the project uses.
  interactive =
    let
      wrapperCache =
        lockFile:
        (import ../nix/lib/interactive.nix {
          inherit pkgs lockFile;
        }).tree;
    in
    evalCheck "interactive" (
      (wrapperCache ./fixtures/app/package-lock.json).outPath == app.cache.outPath
      && (wrapperCache ./fixtures/paths/app/package-lock.json).outPath == paths.cache.outPath
    ) "the cache the wrapper builds differs from the cache the build uses";

  # The wrapper itself builds.
  npm = withOverlay.npm-purifier.npm;

  # The unit tests of the lock run (pkgs/npm/nix-lock.test.js).
  lock-run-units =
    pkgs.runCommand "lock-run-units"
      {
        nativeBuildInputs = [ pkgs.nodejs ];
        NPM_PURIFIER_NPM_MODULES = "${pkgs.nodejs}/lib/node_modules/npm/node_modules";
      }
      ''
        cp ${../pkgs/npm/nix-lock.js} nix-lock.js
        cp ${../pkgs/npm/nix-lock.test.js} nix-lock.test.js
        node --test nix-lock.test.js
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
      map (d: d.path) (readLock host lock).downloads == [
        "content-v2/sha512/53/f2/28e3ee0187efec90cbcd65cecff5e540b1ca425680a6a1b1e77bae878c92a929f314e4c3e668e9775bcdf366ad487f7929d3767e9621f25c91beb2f38b22"
      ]
    ) "the cache path of an integrity is not the one npm uses";

  # Lockfiles the reader refuses, each with a message that names the
  # problem: a git dependency the purifier lockfile lacks, a lockfile older
  # than npm 7, a source that is neither a tarball URL, a repository nor a
  # path, and a tarball without an integrity.
  missing-entry =
    let
      purifierLock = builtins.toFile "npm-purifier.lock.json" (
        builtins.toJSON {
          version = 1;
          packageLockSha256 = builtins.hashString "sha256" (builtins.toJSON gitLock);
          git = { };
        }
      );
    in
    evalCheck "missing-entry" (fails
      (import ../nix/lib/lock.nix {
        inherit lib;
        platform = host;
        lockFile = builtins.toFile "package-lock.json" (builtins.toJSON gitLock);
        purifierLockFile = purifierLock;
      }).git
    ) "a git dependency without an entry in npm-purifier.lock.json evaluated";
  old-lockfile = evalCheck "old-lockfile" (fails
    (readLock host {
      lockfileVersion = 1;
      dependencies = { };
    }).downloads
  ) "a lockfileVersion 1 lockfile evaluated";
  unknown-source = evalCheck "unknown-source" (fails
    (readLock host {
      lockfileVersion = 3;
      packages."node_modules/a".resolved = "ftp://example.invalid/a.tgz";
    }).downloads
  ) "a dependency from ftp evaluated";
  missing-integrity = evalCheck "missing-integrity" (fails
    (readLock host {
      lockfileVersion = 3;
      packages."node_modules/a".resolved = "https://registry.npmjs.org/a/-/a-1.0.0.tgz";
    }).downloads
  ) "a tarball without an integrity evaluated";

  # A tarball whose bytes do not match its integrity fails the install:
  # here the fetcher hands npm another file.
  tampered-tarball =
    let
      tampered = buildNpmProject {
        src = ./fixtures/app;
        fetchurl = { name, ... }: pkgs.writeText name "not the tarball";
      };
    in
    pkgs.runCommand "tampered-tarball-check" { } ''
      grep -q 'seems to be corrupted' ${pkgs.testers.testBuildFailure tampered.build}/testBuildFailure.log
      touch $out
    '';

  # A commit object that is not the locked commit fails the build of the
  # repository, with a message that names the commit.
  tampered-commit =
    let
      entries =
        (import ../nix/lib/lock.nix {
          inherit lib;
          platform = host;
          lockFile = ./fixtures/git/package-lock.json;
        }).git;
      clone = entries.${cloneResolved};
      tampered = clone // {
        git = clone.git // {
          rev = "0000000000000000000000000000000000000000";
        };
      };
      made =
        (pkgs.callPackage ../nix/lib/git.nix {
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
