#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-rebuild: `nix build --rebuild` of a fixture gives the same
# output. The fixture's package and its release (the tarballs
# `npm-purifier publish` uploads) are built, then built again and compared
# by Nix.
#
# Usage: tests/conformance-rebuild.sh, from any directory, with Nix.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

for attribute in packages.hello-npm release; do
  expr="
    let
      f = builtins.getFlake \"git+file://$root\";
    in
    (f.lib.npm-purifier.buildNpmProject {
      pkgs = import f.inputs.nixpkgs { system = builtins.currentSystem; };
      src = $root/tests/fixtures/app;
    }).$attribute
  "
  nix build --impure --no-link --expr "$expr"
  nix build --impure --no-link --rebuild --expr "$expr"
  echo "conformance-rebuild: $attribute builds the same again"
done
