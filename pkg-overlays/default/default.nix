# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.npm-purifier`: the command `npm-purifier` and the `npm` wrapper. A
# consumer that lists this flake in `projects` holds it as
# `npm-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "npm-purifier";
}
