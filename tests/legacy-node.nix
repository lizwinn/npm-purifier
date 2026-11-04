# SPDX-License-Identifier: MIT
{ pkgs, buildNpmProject }:
let
  node = import ./node-fixture.nix {
    inherit pkgs;
    version = "12.22.12";
  };
  project = buildNpmProject {
    src = ./fixtures/legacy-node;
    inherit node;
    doCheck = true;
    nativeBuildInputs = [ ];
  };
in
pkgs.runCommand "npm-legacy-node"
  {
    passthru = { inherit (project) release; };
    nativeBuildInputs = [
      project.packages.legacy-npm-app
      pkgs.python3
    ];
  }
  ''
    test "$(legacy-npm-app)" = "42 on v12.22.12"
    test ! -e ${project.packages.legacy-npm-app}/lib/node_modules/is-odd
    test "$(tar -xOf ${project.release}/legacy-npm-app.tgz package/built.txt)" = v12.22.12
    python - ${project.release.graph}/graph.json <<'PY'
    import json, sys
    graph = json.load(open(sys.argv[1]))
    assert graph['nodeVersion'] == '12.22.12'
    assert graph['nodeAbi'] == '72'
    assert graph['targetRuntime']['version'] != graph['helperRuntime']['version']
    PY
    test -e ${project.packages.legacy-npm-app.projections.npm.catalog}
    touch "$out"
  ''
