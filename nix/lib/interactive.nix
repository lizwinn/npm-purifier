# SPDX-License-Identifier: MIT
#
# What the `npm` wrapper builds for a project: the cache content of the
# tarballs its package-lock.json names, the same tree a sandboxed build
# links into its cache. The wrapper evaluates this file with the lockfile's
# absolute path and keeps the result alive with a GC root.
{
  pkgs,
  lockFile,
}:
pkgs.callPackage ./dependencies.nix {
  inherit
    (import ./lock.nix {
      inherit (pkgs) lib;
      inherit lockFile;
      platform = pkgs.stdenv.hostPlatform;
    })
    downloads
    ;
}
