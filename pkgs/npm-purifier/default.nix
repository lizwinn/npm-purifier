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
  purifier,
  writeShellApplication,
  nodejs,
  pkgs,
  hostNode ? pkgs.nodejs,
  python3,
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
    python3
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
    toolLockfile=
    if [ -n "''${NPM_PURIFIER_TOOL_LOCKFILE:-}" ]; then
      toolLockfile="$(realpath -m "$NPM_PURIFIER_TOOL_LOCKFILE")"
    fi
    inputArgs=()
    rest=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --input)
          [ "$#" -ge 2 ] || usage
          inputArgs+=(--input "$2")
          shift 2
          ;;
        --input=*)
          inputArgs+=(--input "''${1#--input=}")
          shift
          ;;
        --lockfile)
          [ "$#" -ge 2 ] || usage
          lockfile="$(realpath -m "$2")"
          shift 2
          ;;
        --lockfile=*)
          lockfile="$(realpath -m "''${1#--lockfile=}")"
          shift
          ;;
        --tool-lockfile)
          [ "$#" -ge 2 ] || usage
          toolLockfile="$(realpath -m "$2")"
          shift 2
          ;;
        --tool-lockfile=*)
          toolLockfile="$(realpath -m "''${1#--tool-lockfile=}")"
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
        node = ${(import ../../nix/lib/sdk-expression.nix nodejs).shell};
        pkgs = import f.inputs.nixpkgs {
          system = \"$system\";
          overlays = [ f.overlays.default ];
        };
        packageLock = /. + builtins.getEnv \"NPM_PURIFIER_PACKAGE_LOCK\";
        lockFile = /. + builtins.getEnv \"NPM_PURIFIER_LOCKFILE\";
        toolLockFile =
          let
            path = builtins.getEnv \"NPM_PURIFIER_TOOL_LOCKFILE\";
          in
          if path == \"\" then null else /. + path;
      })"
    export NPM_PURIFIER_PACKAGE_LOCK="$root/package-lock.json"
    export NPM_PURIFIER_LOCKFILE="$lockfile"
    export NPM_PURIFIER_TOOL_LOCKFILE="$toolLockfile"

    # withToolLockfile <command>...: runs the command with the outside
    # package-lock.json put where the package-lock.json of the project
    # lies. When the outside file does not exist yet, the command starts
    # from the file in the project. The file the command leaves goes to the
    # outside path, and the file in the project is restored afterwards.
    # Without an outside package-lock.json, the command runs as it is.
    withToolLockfile() {
      if [ -z "$toolLockfile" ]; then
        "$@"
        return
      fi
      local tree="$root/package-lock.json" saved status=0
      saved="$(mktemp)"
      if [ -f "$tree" ]; then
        cp "$tree" "$saved"
      else
        rm -f "$saved"
      fi
      if [ -f "$toolLockfile" ]; then
        cp "$toolLockfile" "$tree"
      fi
      "$@" || status=$?
      if [ -f "$tree" ]; then
        mkdir -p "$(dirname "$toolLockfile")"
        cp "$tree" "$toolLockfile"
      fi
      if [ -f "$saved" ]; then
        mv "$saved" "$tree"
      else
        rm -f "$tree"
      fi
      return "$status"
    }

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
      checkJson "$toolLockfile" "run \`npm-purifier lock\` to write it again"
      checkJson "$lockfile" "run \`npm-purifier lock\` to write it again"
    }

    if [ "$command" = lock ] || [ "$command" = update ] || [ "$command" = inputs ] || [ "$command" = prefetch ]; then
      refreshArgs=()
      if [ "$command" = update ]; then refreshArgs=(--refresh); fi
      python ${../../nix/lib/npm-inputs.py} ${purifier.projectInputsTool} \
        "$lockfile" "$state" ${../../nix/lib/npm-bindings.cjs} \
        ${nodejs}/lib/node_modules/npm/node_modules "''${inputArgs[@]}" "''${refreshArgs[@]}"
      # shellcheck disable=SC1091
      source "$state/input-environment"
    fi
    case "$command" in
      inputs)
        exit
        ;;
      lock)
        withToolLockfile env \
          NPM_PURIFIER_NPM_MODULES=${hostNode}/lib/node_modules/npm/node_modules \
          NPM_PURIFIER_NPM="$npm" \
          ${hostNode}/bin/node ${./lock.js} "$root" "$lockfile"
        ;;
      update)
        updateAndLock() {
          (cd "$root" && "$npm" update --package-lock-only --ignore-scripts --no-audit --no-fund "''${rest[@]}")
          NPM_PURIFIER_NPM_MODULES=${hostNode}/lib/node_modules/npm/node_modules \
            NPM_PURIFIER_NPM="$npm" \
            ${hostNode}/bin/node ${./lock.js} "$root" "$lockfile"
        }
        withToolLockfile updateAndLock
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
        stamp="$( { printf '%s\n' ${nodejs} ${../..}; cat "''${lockfiles[@]}"; } | sha256sum | cut -d' ' -f1)"
        printf '%s %s\n' "$stamp" "$lockfile" > "$state/stamp"
        echo "npm-purifier: npm runs offline in $root through the npm-purifier npm wrapper" >&2
        ;;
      publish)
        checkLockfiles
        name="$(node -p 'require("./package.json").name')"
        echo "npm-purifier: building $name" >&2
        if node -e 'const fs=require("fs");const p=process.argv[1];process.exit(fs.existsSync(p) && (JSON.parse(fs.readFileSync(p)).projectInputs || []).length ? 0 : 1)' "$lockfile"; then
          projection="$project.packages.\''${builtins.getEnv \"NPM_PURIFIER_PACKAGE\"}.projections.npm"
          repository="$(NPM_PURIFIER_PACKAGE="$name" nix build --impure --no-link --print-out-paths --expr "$projection")"
          catalog="$(NPM_PURIFIER_PACKAGE="$name" nix eval --impure --raw --expr "$projection.catalog")"
          exec ${hostNode}/bin/node ${../../nix/lib/npm-publish.cjs} "$npm" "$repository" "$catalog" "''${rest[@]}"
        fi
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
