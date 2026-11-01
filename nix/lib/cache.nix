# SPDX-License-Identifier: MIT
#
# Everything npm reads offline for one project, shared by the sandboxed
# build and the `npm` wrapper. It returns
#
#   tree          the content of npm's cache (`_cacache`): the locked
#                 tarballs, laid out by the shared purifier library, and
#                 the archives of git dependencies with their index entries
#   environment   shell commands that set up the environment npm runs in:
#                 the preparation of git dependencies and the git settings
#                 for cloned ones
#   needsGit      whether the install clones repositories with git
{
  lib,
  pkgs,
  callPackage,
  symlinkJoin,
  stdenv,
  # The shared purifier library.
  purifier,
  # The lock in memory of the project (read-lock.nix).
  lock,
  # Fetchers that replace those of the purifier library.
  fetchers ? { },
  # Checkouts that replace the fetches of git dependencies (see git.nix).
  gitCheckouts ? { },
}:
let
  # The entries this system's install needs.
  entries = purifier.entriesFor stdenv.hostPlatform.system lock;

  tarballs = purifier.tree (
    {
      inherit pkgs;
      name = "npm-purifier-tarballs";
      entries = builtins.filter (entry: !(entry ? git)) entries;
    }
    // fetchers
  );

  git = callPackage ./git.nix {
    git = lib.listToAttrs (
      map (entry: lib.nameValuePair entry.resolved entry) (builtins.filter (entry: entry ? git) entries)
    );
    inherit purifier fetchers;
    checkouts = gitCheckouts;
  };
in
{
  inherit (git) environment needsGit repositories;
  tree = symlinkJoin {
    name = "npm-purifier-cache";
    paths = [
      tarballs
      git.cache
    ];
  };
}
