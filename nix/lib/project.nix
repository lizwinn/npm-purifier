# SPDX-License-Identifier: MIT
#
# The build `npm-purifier publish` and `npm-purifier prefetch` evaluate:
# buildNpmProject of the project whose package-lock.json is `packageLock`,
# with the npm-purifier.lock.json at `lockFile`. A project that depends on
# local directories outside its own directory builds from the directory
# that holds them all, with the project's directory inside it as
# `projectDir`.
{
  # The library of this flake, with `npm-purifier.buildNpmProject`.
  lib,
  # The package set to build with.
  pkgs,
  packageLock,
  lockFile ? dirOf packageLock + "/npm-purifier.lock.json",
}:
let
  lock = lib.importJSON packageLock;

  # How many directories above the project the farthest local package
  # lies.
  depthOf =
    key:
    let
      leading = parts: if parts != [ ] && lib.head parts == ".." then 1 + leading (lib.tail parts) else 0;
    in
    leading (lib.splitString "/" key);
  depth = lib.foldl' lib.max 0 (map depthOf (builtins.attrNames lock.packages));

  projectRoot = dirOf packageLock;
  up = n: path: if n == 0 then path else up (n - 1) (dirOf path);
  rootParts = lib.filter (p: p != "") (lib.splitString "/" (toString projectRoot));
in
lib.npm-purifier.buildNpmProject {
  inherit pkgs lockFile;
  src = up depth projectRoot;
  projectDir = lib.concatStringsSep "/" (lib.drop (lib.length rootParts - depth) rootParts);
}
