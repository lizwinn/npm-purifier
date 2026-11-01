# SPDX-License-Identifier: MIT
#
# The `npm-purifier` library namespace. It holds the builder
# `buildNpmProject` (nix/lib/build-npm-project.nix), which takes the
# package set to build with as its `pkgs` argument. It also holds
# `readLock` (nix/lib/read-lock.nix), which reads a project's lockfiles
# into the lock in memory of the purifier contract.
{ ... }:
{

  overlay = final: prev: {
    npm-purifier = (prev.npm-purifier or { }) // {
      buildNpmProject = import ../../nix/lib/build-npm-project.nix { lib = final; };
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
