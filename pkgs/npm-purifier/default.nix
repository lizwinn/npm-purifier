# SPDX-License-Identifier: MIT
#
# The command `npm-purifier`, for the project around the current directory
# (the nearest directory upwards with a package.json):
#
#   npm-purifier lock       brings package-lock.json in step with
#                           package.json (`npm install --package-lock-only`),
#                           records the tarball URL and integrity of entries
#                           that lack them, and writes npm-purifier.lock.json
#                           for the git dependencies (lock.js); it keeps
#                           the versions package-lock.json resolves
#   npm-purifier update     updates the dependencies with `npm update`
#                           (every one, or the packages named after it),
#                           then locks as `lock` does
#   npm-purifier prefetch   builds, in the Nix store, the npm cache of every
#                           locked tarball and git dependency, the Node.js
#                           and npm that run the project, and the environment
#                           npm runs in, with a garbage-collector root at
#                           .npm-purifier/dependencies in the project; the
#                           `npm` wrapper then runs offline
#   npm-purifier publish    builds the package in the current directory with
#                           Nix and runs `npm publish` on its tarball,
#                           passing the remaining arguments on
#
# Every command takes `--lockfile <path>`, the npm-purifier.lock.json to
# read and write. Without it, the commands take NPM_PURIFIER_LOCKFILE, and
# without that the one at the project root. The builds
# evaluate this flake (nix/lib/project.nix), so they use the same builder
# and library as a Nix build of the project does.
{
  lib,
  writeShellApplication,
  nodejs,
  coreutils,
  git,
  nix-prefetch-git,
  stdenv,
}:
writeShellApplication {
  name = "npm-purifier";
  runtimeInputs = [
    coreutils
    nodejs
    git
    nix-prefetch-git
  ];
  text = ''
    npm=${lib.getExe' nodejs "npm"}
    flake=${../..}
    system=${stdenv.hostPlatform.system}

    usage() {
      echo "usage: npm-purifier lock|update|prefetch|publish [--lockfile <path>] [arguments]" >&2
      exit 2
    }

    command="''${1:-}"
    [ -n "$command" ] || usage
    shift
    lockfile=
    if [ -n "''${NPM_PURIFIER_LOCKFILE:-}" ]; then
      lockfile="$(realpath -m "$NPM_PURIFIER_LOCKFILE")"
    fi
    rest=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --lockfile)
          [ "$#" -ge 2 ] || usage
          lockfile="$(realpath -m "$2")"
          shift 2
          ;;
        --lockfile=*)
          lockfile="$(realpath -m "''${1#--lockfile=}")"
          shift
          ;;
        *)
          rest+=("$1")
          shift
          ;;
      esac
    done

    # The project root is the nearest directory upwards with a package.json.
    root="$PWD"
    while [ ! -f "$root/package.json" ]; do
      if [ "$root" = / ]; then
        echo "npm-purifier: no package.json here or above" >&2
        exit 1
      fi
      root="$(dirname "$root")"
    done
    lockfile="''${lockfile:-$root/npm-purifier.lock.json}"
    state="$root/.npm-purifier"

    # The build of the project, as nix/lib/project.nix makes it.
    project="
      (let
        f = builtins.getFlake \"path:$flake\";
      in
      import $flake/nix/lib/project.nix {
        inherit (f) lib;
        pkgs = import f.inputs.nixpkgs {
          system = \"$system\";
          overlays = [ f.overlays.default ];
        };
        packageLock = /. + builtins.getEnv \"NPM_PURIFIER_PACKAGE_LOCK\";
        lockFile = /. + builtins.getEnv \"NPM_PURIFIER_LOCKFILE\";
      })"
    export NPM_PURIFIER_PACKAGE_LOCK="$root/package-lock.json"
    export NPM_PURIFIER_LOCKFILE="$lockfile"

    # Nix cannot catch a JSON parse error, so the commands that evaluate
    # the build check the lockfiles first.
    checkJson() {
      if [ -f "$1" ] && ! node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$1" 2> /dev/null; then
        echo "npm-purifier: $1 is not valid JSON; $2" >&2
        exit 1
      fi
    }
    checkLockfiles() {
      checkJson "$root/package-lock.json" "run \`npm install\` to write it again"
      checkJson "$lockfile" "run \`npm-purifier lock\` to write it again"
    }

    case "$command" in
      lock)
        NPM_PURIFIER_NPM_MODULES=${nodejs}/lib/node_modules/npm/node_modules \
          NPM_PURIFIER_NPM="$npm" \
          node ${./lock.js} "$root" "$lockfile"
        ;;
      update)
        (cd "$root" && "$npm" update --package-lock-only --ignore-scripts --no-audit --no-fund "''${rest[@]}")
        NPM_PURIFIER_NPM_MODULES=${nodejs}/lib/node_modules/npm/node_modules \
          NPM_PURIFIER_NPM="$npm" \
          node ${./lock.js} "$root" "$lockfile"
        ;;
      prefetch)
        if [ ! -f "$root/package-lock.json" ]; then
          echo "npm-purifier: $root has no package-lock.json; run \`npm-purifier lock\`" >&2
          exit 1
        fi
        checkLockfiles
        echo "npm-purifier: building the dependencies of $root" >&2
        mkdir -p "$state"
        nix build --impure --out-link "$state/dependencies" --expr "$project.interactive"
        # npm writes index entries, logs and packed tarballs into its cache,
        # so the cache is a writable tree of links into the store.
        rm -rf "$state/npm"
        mkdir -p "$state/npm/_cacache"
        cp -rs --no-preserve=mode "$state/dependencies/cache/." "$state/npm/_cacache"
        # The stamp tells the `npm` wrapper which lockfiles this prefetch
        # was for.
        lockfiles=("$root/package-lock.json")
        if [ -f "$lockfile" ]; then
          lockfiles+=("$lockfile")
        fi
        stamp="$(cat "''${lockfiles[@]}" | sha256sum | cut -d' ' -f1)"
        printf '%s %s\n' "$stamp" "$lockfile" > "$state/stamp"
        echo "npm-purifier: npm runs offline in $root through the npm-purifier npm wrapper" >&2
        ;;
      publish)
        checkLockfiles
        name="$(node -p 'require("./package.json").name')"
        echo "npm-purifier: building $name" >&2
        tarball="$(
          NPM_PURIFIER_PACKAGE="$name" nix build --impure --no-link --print-out-paths --expr "
            $project.packages.\''${builtins.getEnv \"NPM_PURIFIER_PACKAGE\"}.tarball
          "
        )"
        exec "$npm" publish "$tarball/package.tgz" "''${rest[@]}"
        ;;
      *)
        usage
        ;;
    esac
  '';
}
