# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.npm-purifier` (`.npm`), and the builder `pkgs.buildNpmProject`
# (nix/lib/build-npm-project.nix) beside them, where nixpkgs keeps its own
# builders, so a package written for callPackage takes it by name. A
# consumer that lists this flake in `projects` holds it as
# `npm-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "npm-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildNpmProject = final.callPackage ../../nix/lib/build-npm-project.nix { };
    };
}
