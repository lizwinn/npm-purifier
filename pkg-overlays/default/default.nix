# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.npm-purifier` (the command `npm-purifier` and the `npm` wrapper),
# and the builder `pkgs.buildNpmProject` (nix/lib/build-npm-project.nix)
# beside them, where nixpkgs keeps its own builders, so a package written
# for callPackage takes it by name. The builder reads lockfiles with the
# library of this flake. A consumer that lists this flake in `projects`
# holds the overlay as `npm-purifier/default`, which its package sets
# apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "npm-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildNpmProject = final.callPackage (import ../../nix/lib/build-npm-project.nix {
        lib = closure-lib;
      }) { };
    };
}
