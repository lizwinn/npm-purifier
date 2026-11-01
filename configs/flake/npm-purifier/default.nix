# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The scope `npm-purifier` is the `default` entry of this flake's
    # package overlay registry (pkg-overlays/): the package set applies it
    # by default, and the flake exports it as `pkgOverlays` and as the plain
    # `overlays.default`. The scope also holds the builder, which is not a
    # package, so the flake exports the derivations of the scope itself.
    nixpkgs = {
      packages.export.enabled = false;
    };
  };

  # `nix run github:nix-purifiers/npm-purifier -- lock` runs the command
  # `npm-purifier`. `nix develop github:nix-purifiers/npm-purifier` gives a
  # shell with that command, the `npm` wrapper of the everyday loop, and
  # Node.js.
  perSystem =
    { config, pkgs, ... }:
    {
      # The packages are the derivations of the scope: the scope also holds
      # the builder, which is not one.
      packages = lib.filterAttrs (_: lib.isDerivation) pkgs.npm-purifier // {
        default = pkgs.npm-purifier.npm-purifier;
      };
      devShells.default = pkgs.mkShell {
        packages = [
          config.packages.npm
          config.packages.npm-purifier
          pkgs.nodejs
        ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              inherit (lib) purifier npm-purifier;
              overlay = self.overlays.default;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
