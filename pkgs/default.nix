# SPDX-License-Identifier: MIT
{ callPackage, lib, ... }:
let
  npm-purifier = callPackage ./npm-purifier { };
in
{
  # The builder of npm projects (nix/lib/build-npm-project.nix), a package
  # for callPackage in this scope. It reads lockfiles with the library of
  # this flake.
  buildNpmProject = callPackage (import ../nix/lib/build-npm-project.nix { inherit lib; }) { };
  # The command `npm-purifier`: lock, update, prefetch and publish.
  inherit npm-purifier;
  # npm that runs offline on what `npm-purifier prefetch` keeps, in a
  # project with a package-lock.json.
  npm = callPackage ./npm { inherit npm-purifier; };
}
