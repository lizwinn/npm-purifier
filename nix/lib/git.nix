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
# For the first, `cache` holds each archive, packed in Nix from a checkout
# of the commit, with the index entry that makes npm's HTTP cache answer
# the archive URL with it. For the second, `gitConfig` maps each
# repository URL and submodule URL to a checkout in the store that keeps
# its .git directory.
#
# npm prepares a git dependency that has a prepare, build or install
# script: it installs the dependency's own dependencies and runs the
# script before packing it. The Node.js of nixpkgs does that preparation
# with `npm ci` when NIX_NODEJS_BUILDNPMPACKAGE is set, and runs
# `$prefetchNpmDeps --fixup-lockfile package-lock.json` before it.
# `prefetchNpmDeps` is the hook below: it places the lockfile that
# `npm nix-lock` made for a dependency whose repository has none. An
# archive carries that lockfile inside already.
#
# The entries take the shape of the shared purifier library's git entries:
# { path, git = { url, rev, submodules, leaveDotGit }, hash }.
{
  lib,
  runCommand,
  writeText,
  writeShellScript,
  fetchgit,
  openssl,
  # The git dependencies, by their `resolved`, as lock.nix returns them.
  git,
  # Checkouts that replace the fetches of git dependencies, by `resolved`.
  # A dependency npm downloads as an archive takes a plain checkout; one
  # npm clones takes a repository that holds the commit, with its
  # submodules checked out.
  checkouts ? { },
}:
let
  fetch =
    resolved: entry:
    checkouts.${resolved} or (fetchgit {
      inherit (entry.git) url rev leaveDotGit;
      inherit (entry) hash;
      fetchSubmodules = entry.git.submodules;
    });

  archives = lib.filterAttrs (_: entry: entry ? archive) git;
  clones = lib.filterAttrs (_: entry: !(entry ? archive)) git;

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
      lib.mapAttrsToList (resolved: entry: ''
        work="$(mktemp -d)"
        cp -r ${fetch resolved entry} "$work/package"
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
        url=${lib.escapeShellArg entry.archive}
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

  # The settings that point git at the checkouts: each repository URL and
  # submodule URL to its directory in the store, local clones of
  # submodules allowed, and the store's owner trusted.
  gitConfig =
    lib.concatLists (
      lib.mapAttrsToList (
        resolved: entry:
        let
          checkout = fetch resolved entry;
        in
        [
          {
            key = "url.file://${checkout}.insteadOf";
            value = entry.repository;
          }
        ]
        ++ map (s: {
          key = "url.file://${checkout}/${s.path}.insteadOf";
          value = s.url;
        }) (entry.submoduleUrls or [ ])
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
