# SPDX-License-Identifier: MIT
{ pkgs, scope }:
let
  nodejs = import ./node-fixture.nix {
    inherit pkgs;
    version = "12.22.12";
  };
  command = scope.npm-purifier.override {
    inherit nodejs;
    hostNode = pkgs.nodejs;
  };
  npm = scope.npm.override {
    inherit nodejs;
    npm-purifier = command;
  };
in
pkgs.buildEnv {
  name = "npm-legacy-tools";
  paths = [
    (pkgs.lib.lowPrio nodejs)
    npm
    command
  ];
}
