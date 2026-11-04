# SPDX-License-Identifier: MIT
#
# npm, wrapped so that in a project with a package-lock.json it installs
# the locked tarballs and git dependencies from the Nix store, offline:
# the everyday loop of npm-purifier. The wrapper runs npm against what
# `npm-purifier prefetch` keeps in the project's .npm-purifier directory,
# with `offline` set, and runs the prefetch itself first when the lockfiles
# changed since the last one.
#
# The commands that change the lockfile (install, update, uninstall and
# their aliases) resolve against the registry, as npm does without the
# wrapper, and then run `npm-purifier lock`. A command that needs a
# download the lockfiles do not name stops with a message that names
# `npm-purifier lock`. NPM_PURIFIER_LOCKFILE names an npm-purifier.lock.json
# other than the one at the project root, and NPM_PURIFIER=0 turns the
# wrapper off for any command.
{
  lib,
  writeShellApplication,
  nodejs,
  coreutils,
  git,
  npm-purifier,
}:
writeShellApplication {
  name = "npm";
  # Package scripts run `node`; they get the Node.js that runs npm. npm
  # clones git dependencies with git.
  runtimeInputs = [
    coreutils
    nodejs
    git
  ];
  text = ''
    npm=${lib.getExe' nodejs "npm"}
    purifier=${lib.getExe npm-purifier}

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
    if [ -z "$root" ]; then
      echo "npm-purifier: warning: no package-lock.json found; running npm impurely. Run \`npm-purifier lock\` to use Nix-resolved dependencies." >&2
      exec "$npm" "$@"
    fi
    lockfileArgs=()
    if [ -n "''${NPM_PURIFIER_LOCKFILE:-}" ]; then
      lockfileArgs=(--lockfile "$NPM_PURIFIER_LOCKFILE")
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

    state="$root/.npm-purifier"
    (cd "$root" && "$purifier" inputs "''${lockfileArgs[@]}")

    case "$command" in
      install | i | in | ins | inst | insta | instal | isnt | isnta | isntal | isntall | add | \
        update | up | upgrade | udpate | \
        uninstall | unlink | remove | rm | r | un)
        # shellcheck disable=SC1091
        source "$state/input-environment"
        "$npm" "$@"
        "$purifier" lock "''${lockfileArgs[@]}"
        exit
        ;;
    esac

    if [ -z "$root" ]; then
      exec "$npm" "$@"
    fi

    state="$root/.npm-purifier"
    lockfile="''${NPM_PURIFIER_LOCKFILE:-$root/npm-purifier.lock.json}"
    lockfile="$(realpath -m "$lockfile")"
    lockfiles=("$root/package-lock.json")
    if [ -f "$lockfile" ]; then
      lockfiles+=("$lockfile")
    fi
    stamp="$( { printf '%s\n' ${nodejs} ${../..}; cat "''${lockfiles[@]}"; } | sha256sum | cut -d' ' -f1)"
    if [ "$(cat "$state/stamp" 2> /dev/null || true)" != "$stamp $lockfile" ]; then
      (cd "$root" && "$purifier" prefetch "''${lockfileArgs[@]}")
    fi

    # shellcheck disable=SC1091
    source "$state/dependencies/environment"
    export npm_config_cache="$state/npm"
    export npm_config_offline=true
    # The audit and the update check contact the registry even when
    # `offline` is set.
    export npm_config_audit=false
    export npm_config_update_notifier=false
    # node-gyp takes the headers of this Node.js rather than downloading
    # them.
    export npm_config_nodedir=${nodejs}

    log="$(mktemp)"
    trap 'rm -f "$log"' EXIT
    status=0
    "$npm" "$@" 2> >(tee "$log" >&2) || status=$?
    wait
    if [ "$status" -ne 0 ] && grep -q ENOTCACHED "$log"; then
      if [ "$(dirname "$lockfile")" = "$root" ]; then
        echo "npm-purifier: npm needs a download that the lockfiles do not name; run \`npm-purifier lock\`" >&2
      else
        # An external npm-purifier.lock.json completes package-lock.json
        # for the Nix build only; npm reads the project's own file.
        echo "npm-purifier: npm needs a download that package-lock.json does not name; $lockfile lies outside the project, and its completions serve the Nix build only" >&2
      fi
    fi
    exit "$status"
  '';
}
