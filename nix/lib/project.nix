# SPDX-License-Identifier: MIT
#
# The build `npm-purifier publish` and `npm-purifier prefetch` evaluate:
# buildNpmProject of the project whose package-lock.json is `packageLock`,
# with the npm-purifier.lock.json at `lockFile`. A project that depends on
# local directories outside its own directory builds from the directory
# that holds them all, with the project's directory inside it as
# `projectDir`.
{
  # The library of this flake.
  lib,
  # The package set to build with, with the default overlay of this flake,
  # which adds the scope `npm-purifier`.
  pkgs,
  node ? pkgs.nodejs,
  packageLock,
  lockFile ? dirOf packageLock + "/npm-purifier.lock.json",
  # A package-lock.json kept outside the project, which the build installs
  # from in place of `packageLock`, or null.
  toolLockFile ? null,
}:
let
  lock = lib.importJSON (if toolLockFile != null then toolLockFile else packageLock);

  # How many directories above the project the farthest local package
  # lies.
  depthOf =
    key:
    let
      leading = parts: if parts != [ ] && lib.head parts == ".." then 1 + leading (lib.tail parts) else 0;
    in
    leading (lib.splitString "/" key);
  depth = lib.foldl' lib.max 0 (map depthOf (builtins.attrNames (lock.packages or { })));

  projectRoot = dirOf packageLock;
  up = n: path: if n == 0 then path else up (n - 1) (dirOf path);
  rootParts = lib.filter (p: p != "") (lib.splitString "/" (toString projectRoot));
in
pkgs.npm-purifier.buildNpmProject (
  {
    inherit lockFile node;
    src = up depth projectRoot;
    projectDir = lib.concatStringsSep "/" (lib.drop (lib.length rootParts - depth) rootParts);
  }
  // lib.optionalAttrs (toolLockFile != null) { packageLock = toolLockFile; }
)
