# SPDX-License-Identifier: MIT
#
# npm, wrapped so that in a project with a package-lock.json it installs
# the locked tarballs from the Nix store, offline. The wrapper builds the
# lockfile's tarballs into a cache through Nix (nix/lib/interactive.nix),
# under $XDG_CACHE_HOME/npm-purifier, and runs npm against that cache with
# `offline` set. It rebuilds the cache when the lockfile changes.
#
# The commands that change the lockfile (install, update, uninstall and
# their aliases) resolve against the registry, as npm does without the
# wrapper. NPM_PURIFIER=0 turns the wrapper off for any command.
{
  lib,
  writeShellApplication,
  nodejs,
  coreutils,
  path,
  stdenv,
}:
writeShellApplication {
  name = "npm";
  # Package scripts run `node`; they get the Node.js that runs npm.
  runtimeInputs = [
    coreutils
    nodejs
  ];
  text = ''
    npm=${lib.getExe' nodejs "npm"}

    if [ "''${NPM_PURIFIER:-1}" = 0 ]; then
      exec "$npm" "$@"
    fi

    # The first argument that is not an option is npm's command.
    command=
    for arg in "$@"; do
      case "$arg" in
        -*) ;;
        *)
          command="$arg"
          break
          ;;
      esac
    done
    case "$command" in
      install | i | in | ins | inst | insta | instal | isnt | isnta | isntal | isntall | add | \
        update | up | upgrade | udpate | \
        uninstall | unlink | remove | rm | r | un)
        exec "$npm" "$@"
        ;;
    esac

    # The project root is the nearest directory upwards with a lockfile.
    dir="$PWD"
    while [ ! -f "$dir/package-lock.json" ]; do
      if [ "$dir" = / ]; then
        exec "$npm" "$@"
      fi
      dir="$(dirname "$dir")"
    done
    lock="$dir/package-lock.json"

    cache="''${XDG_CACHE_HOME:-$HOME/.cache}/npm-purifier/$(printf '%s' "$lock" | sha256sum | cut -c1-32)"
    stamp="$(sha256sum < "$lock" | cut -d' ' -f1)"
    if [ "$(cat "$cache/lock.sha256" 2> /dev/null || true)" != "$stamp" ]; then
      echo "npm-purifier: building the tarballs of $lock" >&2
      mkdir -p "$cache"
      NPM_PURIFIER_LOCK="$lock" nix build --impure --out-link "$cache/dependencies" --expr '
        import ${../../nix/lib}/interactive.nix {
          pkgs = import ${path} { system = "${stdenv.hostPlatform.system}"; };
          lockFile = /. + builtins.getEnv "NPM_PURIFIER_LOCK";
        }
      '
      # npm writes index entries, logs and packed tarballs into its cache,
      # so the cache is a writable tree of links into the store.
      rm -rf "$cache/npm"
      mkdir -p "$cache/npm/_cacache"
      cp -rs --no-preserve=mode "$cache/dependencies/." "$cache/npm/_cacache"
      printf '%s\n' "$stamp" > "$cache/lock.sha256"
    fi

    export npm_config_cache="$cache/npm"
    export npm_config_offline=true
    # The audit and the update check contact the registry even when
    # `offline` is set.
    export npm_config_audit=false
    export npm_config_update_notifier=false
    exec "$npm" "$@"
  '';
}
