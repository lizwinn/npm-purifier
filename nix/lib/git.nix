# SPDX-License-Identifier: MIT
#
# Serves a project's git dependencies to npm offline. npm skips the
# integrity of a git dependency and fetches it again on every install, in
# one of two ways:
#
#   - from a known host (GitHub, GitLab, Bitbucket, sourcehut), it
#     downloads the host's archive of the commit through its HTTP cache,
#     which looks a response up by its URL;
#   - from any other repository, it clones the repository with git, checks
#     out the commit and updates the submodules.
#
# Each dependency is a git entry of the shared purifier library,
# { path, git = { url, rev, submodules, leaveDotGit, commitObject }, hash },
# which the library fetches. readLock (read-lock.nix) makes it from the
# dependency's `resolved` in package-lock.json and its entry in
# npm-purifier.lock.json. For the first way, `cache` holds each archive,
# packed in Nix from the checkout, with the index entry that makes npm's
# HTTP cache answer the archive URL with it. For the second, the entry has
# `leaveDotGit`, so the library rebuilds the repository's .git directory
# from the checkout and the recorded commit object; npm clones that
# repository. npm then clones each submodule from its own URL, so the
# entry also lists the submodules with their commits (`submodules`), and
# `repositories` makes a repository for each from its directory in the
# checkout, the same way. `gitConfig` maps every repository URL and
# submodule URL to its repository in the store.
#
# npm prepares a git dependency that has a prepare, build or install
# script: it installs the dependency's own dependencies and runs the
# script before packing it. The Node.js of nixpkgs does that preparation
# with `npm ci` when NIX_NODEJS_BUILDNPMPACKAGE is set, and runs
# `$prefetchNpmDeps --fixup-lockfile package-lock.json` before it.
# `prefetchNpmDeps` is the hook below: it places the lockfile that
# `npm-purifier lock` made for a dependency whose repository has none. An
# archive carries that lockfile inside already.
{
  lib,
  runCommand,
  writeText,
  writeShellScript,
  gitMinimal,
  openssl,
  # What fetchEntry of the purifier library fetches and builds with.
  fetchurl,
  fetchgit,
  unzip,
  zstd,
  python3,
  # The shared purifier library.
  purifier,
  # Fetchers that replace those of the purifier library.
  fetchers ? { },
  # The git dependencies, by their `resolved`, as the entries readLock
  # returns.
  git,
  # Plain checkouts, with submodules checked out where npm clones them,
  # that replace the fetches of git dependencies, by `resolved`.
  checkouts ? { },
}:
let
  # The checkouts by URL and commit, for the fetcher the library calls.
  replacements = lib.mapAttrs' (
    resolved: checkout:
    lib.nameValuePair "${git.${resolved}.git.url}#${git.${resolved}.git.rev}" checkout
  ) (lib.filterAttrs (resolved: _: git ? ${resolved}) checkouts);

  fetchEntry = purifier.fetchEntry (
    {
      inherit
        fetchurl
        runCommand
        unzip
        zstd
        python3
        writeText
        ;
    }
    // fetchers
    // {
      fetchgit = args: replacements."${args.url}#${args.rev}" or ((fetchers.fetchgit or fetchgit) args);
    }
  );

  # The library entry of a dependency, without the fields only npm needs.
  entryOf = entry: {
    inherit (entry) path git hash;
  };

  archives = lib.filterAttrs (_: entry: entry ? archiveUrl) git;
  clones = lib.filterAttrs (_: entry: !(entry ? archiveUrl)) git;

  lockFileOf = entry: writeText "package-lock.json" (builtins.toJSON entry.packageLock);
  injected = entry: entry.injectPackageLock or false;
  subdirOf = entry: entry.subdir or "";

  # The archive npm would download, packed from the checkout with the
  # prepared lockfile added, and its cache content and index entry. The
  # index entry is written in the build, because the archive's integrity
  # is known only there.
  cache = runCommand "npm-purifier-git-archives" { nativeBuildInputs = [ openssl ]; } ''
    mkdir -p "$out"
    ${lib.concatStrings (
      lib.mapAttrsToList (_: entry: ''
        work="$(mktemp -d)"
        cp -r ${fetchEntry (entryOf entry)} "$work/package"
        chmod -R u+w "$work/package"
        ${lib.optionalString (injected entry) ''
          cp ${lockFileOf entry} "$work/package/"${lib.escapeShellArg (subdirOf entry)}/package-lock.json
        ''}
        tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$work" -cf - package \
          | gzip -9n > "$work/archive.tgz"
        hex="$(sha512sum "$work/archive.tgz" | cut -d' ' -f1)"
        integrity="sha512-$(openssl dgst -sha512 -binary "$work/archive.tgz" | base64 -w0)"
        content="$out/content-v2/sha512/''${hex:0:2}/''${hex:2:2}/''${hex:4}"
        mkdir -p "$(dirname "$content")"
        cp "$work/archive.tgz" "$content"
        url=${lib.escapeShellArg entry.archiveUrl}
        key="make-fetch-happen:request-cache:$url"
        json="{\"key\":\"$key\",\"integrity\":\"$integrity\",\"time\":0,\"metadata\":{\"url\":\"$url\",\"reqHeaders\":{},\"resHeaders\":{},\"options\":{\"compress\":true}}}"
        keyHash="$(printf '%s' "$key" | sha256sum | cut -d' ' -f1)"
        bucket="$out/index-v5/''${keyHash:0:2}/''${keyHash:2:2}/''${keyHash:4}"
        mkdir -p "$(dirname "$bucket")"
        printf '\n%s\t%s' "$(printf '%s' "$json" | sha1sum | cut -d' ' -f1)" "$json" >> "$bucket"
        rm -rf "$work"
      '') archives
    )}
  '';

  # The repositories of a cloned dependency: `repository` is the library's
  # checkout with its .git directory, and `modules/<path>` is a repository
  # made for the submodule at <path>: its directory in the checkout written
  # as the tree of the recorded commit, the commit object written and
  # checked against the commit, and the repository marked shallow at it.
  repositories =
    resolved: entry:
    let
      checkout = fetchEntry (entryOf entry);
      make = s: ''
        make "$out/modules/"${lib.escapeShellArg s.path} ${checkout}/${lib.escapeShellArg s.path} ${s.rev} ${lib.escapeShellArg s.commitObject.object} ${
          lib.escapeShellArgs (map (l: "${l.path}=${l.rev}") s.commitObject.gitlinks)
        }
      '';
    in
    runCommand "npm-purifier-git-repositories" { nativeBuildInputs = [ gitMinimal ]; } ''
      export HOME="$TMPDIR"
      git config --global safe.directory '*'
      # make <repository> <directory> <commit> <commit object, base64>
      #   [<submodule path>=<submodule commit>]...
      make() {
        local dest="$1" work="$2" rev="$3" object="$4"
        shift 4
        git init -q --bare "$dest"
        export GIT_DIR="$dest" GIT_INDEX_FILE="$TMPDIR/index"
        rm -f "$GIT_INDEX_FILE"
        git --work-tree="$work" add -A -f .
        for link in "$@"; do
          git rm -r -q --cached --ignore-unmatch "''${link%%=*}"
          git update-index --add --cacheinfo "160000,''${link#*=},''${link%%=*}"
        done
        tree="$(git write-tree)"
        printf '%s' "$object" | base64 -d > "$TMPDIR/commit"
        want="$(sed -n '1s/^tree //p' "$TMPDIR/commit")"
        if [ "$tree" != "$want" ]; then
          echo "npm-purifier: the checkout of $rev gives tree $tree, not the commit's tree $want" >&2
          exit 1
        fi
        if [ "$(git hash-object -t commit -w "$TMPDIR/commit")" != "$rev" ]; then
          echo "npm-purifier: the recorded commit object is not commit $rev" >&2
          exit 1
        fi
        echo "$rev" > "$dest/shallow"
        git update-ref refs/heads/main "$rev"
        git symbolic-ref HEAD refs/heads/main
        unset GIT_DIR GIT_INDEX_FILE
      }
      mkdir -p "$out/modules"
      ln -s ${checkout} "$out/repository"
      ${lib.concatMapStrings make (entry.submodules or [ ])}
    '';

  # The settings that point git at the repositories: each repository URL
  # and submodule URL to its repository in the store, local clones of
  # submodules allowed, and the store's owner trusted.
  gitConfig =
    lib.concatLists (
      lib.mapAttrsToList (
        resolved: entry:
        let
          made = repositories resolved entry;
        in
        [
          {
            key = "url.file://${made}/repository.insteadOf";
            value = entry.repository;
          }
        ]
        ++ map (s: {
          key = "url.file://${made}/modules/${s.path}.insteadOf";
          value = s.url;
        }) (entry.submodules or [ ])
      ) clones
    )
    ++ lib.optionals (clones != { }) [
      {
        key = "protocol.file.allow";
        value = "always";
      }
      {
        key = "safe.directory";
        value = "*";
      }
    ];

  # The lockfiles for cloned dependencies without one, at
  # <commit>/<directory in the repository>/package-lock.json.
  preparationLocks = runCommand "npm-purifier-git-locks" { } ''
    mkdir -p "$out"
    ${lib.concatStrings (
      lib.mapAttrsToList (
        _: entry:
        lib.optionalString (injected entry) ''
          mkdir -p "$out"/${lib.escapeShellArg "${entry.git.rev}/${subdirOf entry}"}
          cp ${lockFileOf entry} "$out"/${lib.escapeShellArg "${entry.git.rev}/${subdirOf entry}"}/package-lock.json
        ''
      ) clones
    )}
  '';

  prefetchNpmDeps = writeShellScript "npm-purifier-prepare-git" ''
    if [ -e package-lock.json ] || [ -e npm-shrinkwrap.json ]; then
      exit 0
    fi
    rev="$(git rev-parse HEAD 2> /dev/null)" || exit 0
    prefix="$(git rev-parse --show-prefix)"
    lock=${preparationLocks}/"$rev/$prefix"package-lock.json
    if [ -f "$lock" ]; then
      cp "$lock" package-lock.json
      chmod u+w package-lock.json
    fi
  '';
in
{
  inherit cache gitConfig prefetchNpmDeps;
  # The repositories made for each cloned dependency, by `resolved`.
  repositories = lib.mapAttrs repositories clones;
  # Whether the install clones repositories with git.
  needsGit = clones != { };
  # The shell commands that set up the environment npm runs in.
  environment = ''
    export NIX_NODEJS_BUILDNPMPACKAGE=1
    export prefetchNpmDeps=${prefetchNpmDeps}
    # npm prepares a git dependency with its dev dependencies, also in an
    # install that leaves out the project's own (`--omit=dev`); nixpkgs
    # adds these flags to the `npm ci` of the preparation.
    export npmInstallFlags=--include=dev
    export GIT_CONFIG_COUNT=${toString (builtins.length gitConfig)}
    ${lib.concatStrings (
      lib.imap0 (i: c: ''
        export GIT_CONFIG_KEY_${toString i}=${lib.escapeShellArg c.key}
        export GIT_CONFIG_VALUE_${toString i}=${lib.escapeShellArg c.value}
      '') gitConfig
    )}
  '';
}
