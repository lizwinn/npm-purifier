# SPDX-License-Identifier: MIT
#
# The builds `npm nix-publish` publishes from: buildNpmProject of the
# project whose package-lock.json is `lockFile`. A project that depends on
# local directories outside its own directory builds from the directory
# that holds them all, with the project's directory inside it as
# `projectDir`.
{
  pkgs,
  lockFile,
}:
let
  inherit (pkgs) lib;

  lock = lib.importJSON lockFile;

  # How many directories above the project the farthest local package
  # lies.
  depthOf =
    key:
    let
      leading = parts: if parts != [ ] && lib.head parts == ".." then 1 + leading (lib.tail parts) else 0;
    in
    leading (lib.splitString "/" key);
  depth = lib.foldl' lib.max 0 (map depthOf (builtins.attrNames lock.packages));

  projectRoot = dirOf lockFile;
  up = n: path: if n == 0 then path else up (n - 1) (dirOf path);
  rootParts = lib.filter (p: p != "") (lib.splitString "/" (toString projectRoot));
in
(pkgs.callPackage ./build-npm-project.nix { }) {
  src = up depth projectRoot;
  projectDir = lib.concatStringsSep "/" (lib.drop (lib.length rootParts - depth) rootParts);
  inherit lockFile;
}
