# SPDX-License-Identifier: MIT
#
# What the `npm` wrapper builds for a project: the content of npm's cache
# for its lockfiles, the same tree a sandboxed build links into its cache,
# in `cache/`, and the shell commands that set up the environment npm runs
# in, in `environment`. The wrapper evaluates this file with the lockfile's
# absolute path and keeps the result alive with a GC root.
{
  pkgs,
  lockFile,
}:
let
  cache = pkgs.callPackage ./cache.nix { inherit lockFile; };
in
pkgs.runCommand "npm-purifier-interactive"
  {
    passAsFile = [ "environment" ];
    # The Node.js of nixpkgs prepares git dependencies with stdenv's
    # patchShebangs, which it loads from $stdenv/setup.
    environment = ''
      export stdenv=${pkgs.stdenv}
      ${cache.environment}
    '';
    passthru.tree = cache.tree;
  }
  ''
    mkdir -p "$out"
    ln -s ${cache.tree} "$out/cache"
    cp "$environmentPath" "$out/environment"
  ''
