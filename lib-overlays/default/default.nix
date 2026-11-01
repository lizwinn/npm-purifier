# SPDX-License-Identifier: MIT
#
# The `npm-purifier` library namespace. It holds `readLock`
# (nix/lib/read-lock.nix), which reads a project's lockfiles into the lock
# in memory of the purifier contract. The builder `buildNpmProject` is a
# package, which the default package overlay adds to the package set.
{ ... }:
{

  overlay = final: prev: {
    npm-purifier = (prev.npm-purifier or { }) // {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
