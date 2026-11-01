# SPDX-License-Identifier: MIT
#
# The `npm-purifier` library namespace: the builder `buildNpmProject`
# (nix/lib/build-npm-project.nix), which takes the package set to build
# with as its `pkgs` argument.
{ ... }:
{

  overlay = final: prev: {
    npm-purifier = (prev.npm-purifier or { }) // {
      buildNpmProject = import ../../nix/lib/build-npm-project.nix { lib = final; };
    };
  };

}
