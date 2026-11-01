# SPDX-License-Identifier: MIT
{ callPackage, ... }:
let
  npm-purifier = callPackage ./npm-purifier { };
in
{
  # The command `npm-purifier`: lock, prefetch and publish.
  inherit npm-purifier;
  # npm that runs offline on what `npm-purifier prefetch` keeps, in a
  # project with a package-lock.json.
  npm = callPackage ./npm { inherit npm-purifier; };
}
