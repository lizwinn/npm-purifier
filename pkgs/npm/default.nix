# SPDX-License-Identifier: MIT
#
# npm, wrapped so that in a project with a package-lock.json it installs
# the locked tarballs and git dependencies from the Nix store, offline.
# The wrapper builds the project's cache through Nix
# (the `interactive` attribute of buildNpmProject, from this flake), under
# $XDG_CACHE_HOME/npm-purifier, and runs
# npm against that cache with `offline` set. It rebuilds the cache when a
# lockfile changes.
#
# The commands that change the lockfile (install, update, uninstall and
# their aliases) resolve against the registry, as npm does without the
# wrapper, and then run the lock run. Two commands are the wrapper's own:
#
#   npm nix-lock      the lock run (pkgs/npm/nix-lock.js): it writes
#                     npm-purifier.lock.json for the git dependencies of
#                     package-lock.json, reusing the entries it has
#   npm nix-publish   publishes the package in the current directory as
#                     Nix builds it (nix/lib/publish.nix), passing the
#                     remaining arguments to `npm publish`
#
# NPM_PURIFIER=0 turns the wrapper off for any command.
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
  name = "npm";
  # Package scripts run `node`; they get the Node.js that runs npm. npm
  # clones git dependencies with git, and the lock run fetches them with
  # nix-prefetch-git.
  runtimeInputs = [
    coreutils
    nodejs
    git
    nix-prefetch-git
  ];
  text = ''
    npm=${lib.getExe' nodejs "npm"}
    # The nixpkgs this flake pins, with its overlay, which builds the cache
    # and the packages with the same builder and library as a Nix build
    # does.
    flake=${../..}
    pkgs="(let f = builtins.getFlake \"path:$flake\"; in import f.inputs.nixpkgs {
      system = \"${stdenv.hostPlatform.system}\";
      overlays = [ f.overlays.default ];
    })"

    if [ "''${NPM_PURIFIER:-1}" = 0 ]; then
      exec "$npm" "$@"
    fi

    # The project root is the nearest directory upwards with a lockfile.
    root=
    dir="$PWD"
    while [ "$dir" != / ]; do
      if [ -f "$dir/package-lock.json" ]; then
        root="$dir"
        break
      fi
      dir="$(dirname "$dir")"
    done

    nixLock() {
      NPM_PURIFIER_NPM_MODULES=${nodejs}/lib/node_modules/npm/node_modules \
        NPM_PURIFIER_NPM="$npm" \
        node ${./nix-lock.js} "$1"
    }

    # The first argument that is not an option is npm's command; `rest`
    # holds the other arguments.
    command=
    rest=()
    for arg in "$@"; do
      if [ -z "$command" ] && [[ "$arg" != -* ]]; then
        command="$arg"
      else
        rest+=("$arg")
      fi
    done

    case "$command" in
      nix-lock)
        if [ -z "$root" ]; then
          echo "npm-purifier: no package-lock.json here or above; run npm install first" >&2
          exit 1
        fi
        nixLock "$root"
        exit
        ;;
      nix-publish)
        if [ -z "$root" ]; then
          echo "npm-purifier: no package-lock.json here or above; run npm install first" >&2
          exit 1
        fi
        name="$(node -p 'require("./package.json").name')"
        echo "npm-purifier: building $name" >&2
        tarball="$(
          NPM_PURIFIER_LOCK="$root/package-lock.json" NPM_PURIFIER_PACKAGE="$name" \
            nix build --impure --no-link --print-out-paths --expr "
              (import $flake/nix/lib/publish.nix {
                pkgs = $pkgs;
                lockFile = /. + builtins.getEnv \"NPM_PURIFIER_LOCK\";
              }).packages.\''${builtins.getEnv \"NPM_PURIFIER_PACKAGE\"}.tarball
            "
        )"
        exec "$npm" publish "$tarball/package.tgz" "''${rest[@]}"
        ;;
      install | i | in | ins | inst | insta | instal | isnt | isnta | isntal | isntall | add | \
        update | up | upgrade | udpate | \
        uninstall | unlink | remove | rm | r | un)
        "$npm" "$@"
        # The lock run keeps npm-purifier.lock.json in step with the new
        # package-lock.json.
        dir="$PWD"
        while [ "$dir" != / ]; do
          if [ -f "$dir/package-lock.json" ]; then
            nixLock "$dir"
            break
          fi
          dir="$(dirname "$dir")"
        done
        exit
        ;;
    esac

    if [ -z "$root" ]; then
      exec "$npm" "$@"
    fi
    lock="$root/package-lock.json"
    purifierLock="$root/npm-purifier.lock.json"

    cache="''${XDG_CACHE_HOME:-$HOME/.cache}/npm-purifier/$(printf '%s' "$lock" | sha256sum | cut -c1-32)"
    lockFiles=("$lock")
    if [ -f "$purifierLock" ]; then
      lockFiles+=("$purifierLock")
    fi
    stamp="$(cat "''${lockFiles[@]}" | sha256sum | cut -d' ' -f1)"
    if [ "$(cat "$cache/lock.sha256" 2> /dev/null || true)" != "$stamp" ]; then
      echo "npm-purifier: building the dependencies of $lock" >&2
      mkdir -p "$cache"
      NPM_PURIFIER_LOCK="$lock" nix build --impure --out-link "$cache/dependencies" --expr "
        let
          lockFile = /. + builtins.getEnv \"NPM_PURIFIER_LOCK\";
        in
        ($pkgs.buildNpmProject {
          src = dirOf lockFile;
          inherit lockFile;
        }).interactive
      "
      # npm writes index entries, logs and packed tarballs into its cache,
      # so the cache is a writable tree of links into the store.
      rm -rf "$cache/npm"
      mkdir -p "$cache/npm/_cacache"
      cp -rs --no-preserve=mode "$cache/dependencies/cache/." "$cache/npm/_cacache"
      printf '%s\n' "$stamp" > "$cache/lock.sha256"
    fi

    # shellcheck disable=SC1091
    source "$cache/dependencies/environment"
    export npm_config_cache="$cache/npm"
    export npm_config_offline=true
    # The audit and the update check contact the registry even when
    # `offline` is set.
    export npm_config_audit=false
    export npm_config_update_notifier=false
    exec "$npm" "$@"
  '';
}
