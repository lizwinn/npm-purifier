# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  debug = false;

  # The scope `npm-purifier` is the `default` entry of the package overlay
  # registry of this flake (pkg-overlays/): the package set applies it by
  # default, and the flake exports it as `pkgOverlays` and as the plain
  # `overlays.default`. The scope also holds the builder, which is not a
  # package, so the module publishes the derivations of the scope as the
  # packages.
  purifier.scope = "npm-purifier";

  caisson.libOverlays.exported = libOverlays: {
    inherit (libOverlays) default;
  };

  # `nix run github:nix-purifiers/npm-purifier -- lock` runs the command
  # `npm-purifier`. `nix develop github:nix-purifiers/npm-purifier` gives a
  # shell with that command, the `npm` wrapper of the everyday loop, and
  # Node.js.
  perSystem =
    { config, pkgs, ... }:
    {
      packages.default = pkgs.npm-purifier.npm-purifier;
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
