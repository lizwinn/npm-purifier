# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked tarballs.
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

  # Evaluates the lockfile reader on a lockfile written inline.
  readLock =
    platform: lock:
    import ../nix/lib/lock.nix {
      inherit lib platform;
      lockFile = builtins.toFile "package-lock.json" (builtins.toJSON lock);
    };
  host = pkgs.stdenv.hostPlatform;

  # A lockfile check passes when `assertion` holds; it fails with
  # `message` otherwise.
  evalCheck =
    name: assertion: message:
    if assertion then
      pkgs.runCommand name { } "touch $out"
    else
      throw "npm-purifier check ${name}: ${message}";
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

  # A git dependency fails evaluation with a message that names it.
  git-dependency =
    let
      result = builtins.tryEval (
        builtins.deepSeq
          (readLock host {
            lockfileVersion = 3;
            packages = {
              "" = {
                name = "p";
              };
              "node_modules/left-pad" = {
                resolved = "git+ssh://git@github.com/left-pad/left-pad.git#2fca6157f8ea5d1c3a0b3e8d2a1c5c3e5d6e7f80";
              };
            };
          }).downloads
          true
      );
    in
    evalCheck "git-dependency" (!result.success) "a lockfile with a git dependency evaluated";

  # The wrapper evaluates nix/lib/interactive.nix for a project; the tree
  # it builds is the one the sandboxed build of the project uses.
  interactive =
    let
      tree = import ../nix/lib/interactive.nix {
        inherit pkgs;
        lockFile = ./fixtures/app/package-lock.json;
      };
    in
    evalCheck "interactive" (
      tree.outPath == app.dependencies.outPath
    ) "the tree the wrapper builds differs from the tree the build uses";

  # The wrapper itself builds.
  npm = withOverlay.npm-purifier.npm;
}
