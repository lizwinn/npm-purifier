# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.npm-purifier`, made with `lib.makeScope`. The scope holds
# the packages of pkgs/ (`.buildNpmProject`, `.npm-purifier`, `.npm`), so a
# package written for callPackage takes `{ npm-purifier }:` and the
# builder as `npm-purifier.buildNpmProject`. `npm-purifier.overrideScope`
# replaces what everything in the scope shares, and
# `npm-purifier.buildNpmProject.override` replaces what the builder takes.
# A consumer that lists this flake in `projects` holds the overlay as
# `npm-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "npm-purifier";
}
