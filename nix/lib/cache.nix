# SPDX-License-Identifier: MIT
#
# Everything npm reads offline for one project, shared by the sandboxed
# build and the `npm` wrapper. It returns
#
#   lock          what lock.nix read from the lockfiles
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
  lockFile,
  purifierLockFile ? dirOf lockFile + "/npm-purifier.lock.json",
  # Replaces the fetcher of the locked tarballs.
  fetchurl ? null,
  # Checkouts that replace the fetches of git dependencies (see git.nix).
  gitCheckouts ? { },
}:
let
  lock = import ./lock.nix {
    inherit
      lib
      lockFile
      purifierLockFile
      purifier
      ;
    inherit (stdenv.hostPlatform) system;
  };

  tarballs = purifier.tree (
    {
      inherit pkgs;
      name = "npm-purifier-tarballs";
      entries = lock.downloads;
    }
    // lib.optionalAttrs (fetchurl != null) { inherit fetchurl; }
  );

  git = callPackage ./git.nix {
    inherit (lock) git;
    inherit purifier;
    checkouts = gitCheckouts;
  };
in
{
  inherit lock;
  inherit (git) environment needsGit repositories;
  tree = symlinkJoin {
    name = "npm-purifier-cache";
    paths = [
      tarballs
      git.cache
    ];
  };
}
