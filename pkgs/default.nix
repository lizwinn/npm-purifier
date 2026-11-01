# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # npm that reads the locked tarballs through Nix, offline, in a project
  # with a package-lock.json.
  npm = callPackage ./npm { };
}
