# SPDX-License-Identifier: MIT
#
# buildNpmProject: sandboxed builds of an npm project, from the
# package-lock.json at its root. The project needs no Nix files of its
# own: the lock names every tarball the install fetches, with its
# integrity, and every package of the project (the root and its
# workspaces).
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The
# npm-purifier overlay (`overlays.default`) adds it to the package set as
# `buildNpmProject`, so a package written for callPackage takes it like any
# other dependency:
#
#   { buildNpmProject }: (buildNpmProject { src = ./.; }).packages.my-app
#
# and `buildNpmProject.override` replaces what it takes from the set. The
# builder returns
#
#   dependencies      the npm cache content of every locked tarball
#   build             the project after `npm ci`, its build scripts and
#                     `npm pack`: one tarball per package of the project
#   productionModules the production dependencies (`npm ci --omit=dev`)
#   packages.<name>   package <name> of the project, installed with its
#                     production dependencies under lib/node_modules, with
#                     its commands in bin/; its `tarball` output holds
#                     package.tgz, the file `npm publish` uploads
{
  lib,
  stdenv,
  callPackage,
  nodejs,
  python3,
}:
{
  # The root of the npm project.
  src,
  # The lockfile; the default is the one npm writes at the project root.
  lockFile ? src + "/package-lock.json",
  # The Node.js that runs npm and the project's scripts, and that the
  # packages' commands run on.
  node ? nodejs,
  # The package scripts that build the project, run in order before the
  # packages are packed. A script the root package defines runs at the
  # root; otherwise it runs in each workspace that defines it.
  buildScripts ? [ "build" ],
  # Runs the `test` script the same way, after the build scripts.
  doCheck ? false,
  # Tools the build scripts and the dependencies' install scripts need.
  # Python is there for node-gyp.
  nativeBuildInputs ? [ python3 ],
  # Libraries native addons link against.
  buildInputs ? [ ],
  # Replaces the fetcher of the locked tarballs.
  fetchurl ? null,
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out installed
  # dependencies, version control and Nix result links.
  srcFilter ? null,
}:
let
  lock = import ./lock.nix {
    inherit lib lockFile;
    platform = stdenv.hostPlatform;
  };

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !((type == "directory" && name == "node_modules") || name == ".git" || lib.hasPrefix "result" name);

  filteredSrc = builtins.path {
    path = src;
    name = "npm-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  dependencies = callPackage ./dependencies.nix (
    {
      inherit (lock) downloads;
    }
    // lib.optionalAttrs (fetchurl != null) { inherit fetchurl; }
  );

  # The file name of a package's tarball in `build`.
  tarballName = p: (builtins.replaceStrings [ "@" "/" ] [ "" "__" ] p.name) + ".tgz";

  # The setup shared by every build: npm runs offline against a cache whose
  # content is the locked tarballs. npm writes index entries, logs and the
  # tarballs `npm pack` makes into the cache, so the cache is a writable
  # tree of links to the tarballs in the store.
  npmSetup = ''
    export HOME="$TMPDIR/home"
    export npm_config_cache="$TMPDIR/npm-cache"
    export npm_config_offline=true
    export npm_config_audit=false
    export npm_config_fund=false
    export npm_config_update_notifier=false
    # node-gyp takes the headers of the Node.js that runs it rather than
    # downloading them. node-gyp reads this variable itself; npm warns
    # that it is not one of npm's own settings.
    export npm_config_nodedir=${node}
    mkdir -p "$HOME" "$npm_config_cache/_cacache"
    cp -rs --no-preserve=mode ${dependencies}/. "$npm_config_cache/_cacache"
  '';

  # Installs the locked dependencies. The sandbox has no /usr/bin/env, so
  # the dependencies' scripts get their interpreters patched between the
  # install and the run of their install scripts.
  npmInstall = flags: ''
    npm ci --ignore-scripts ${lib.escapeShellArgs flags}
    while IFS= read -r -d "" dir; do
      patchShebangs "$dir" > /dev/null
    done < <(find . -name node_modules -type d -prune -print0)
    npm rebuild
  '';

  # Runs package script $1 at the root when the root defines it, and in
  # every workspace that defines it otherwise.
  runScript = ''
    runScript() {
      if node -e 'process.exit(require("./package.json").scripts?.[process.argv[1]] ? 0 : 1)' "$1"; then
        npm run "$1"
      elif node -e 'process.exit(require("./package.json").workspaces ? 0 : 1)'; then
        npm run "$1" --workspaces --if-present
      fi
    }
  '';

  ownPackages = builtins.attrValues lock.packages;

  build = stdenv.mkDerivation {
    name = "npm-project-build";
    src = filteredSrc;
    nativeBuildInputs = [ node ] ++ nativeBuildInputs;
    inherit buildInputs;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      ${npmSetup}
      ${npmInstall [ ]}
      ${runScript}
      for script in ${lib.escapeShellArgs buildScripts}; do
        runScript "$script"
      done
      ${lib.optionalString doCheck "runScript test"}
      runHook postBuild
    '';
    # `npm pack` runs the packages' prepack, prepare and postpack scripts,
    # as `npm publish` does.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      ${lib.concatMapStrings (p: ''
        packdir="$(mktemp -d)"
        npm pack --pack-destination "$packdir" ${
          lib.optionalString (p.dir != "") "--workspace ${lib.escapeShellArg p.dir}"
        } > /dev/null
        mv "$packdir"/*.tgz "$out"/${lib.escapeShellArg (tarballName p)}
      '') ownPackages}
      runHook postInstall
    '';
    # The tarballs are what npm publishes, byte for byte.
    dontFixup = true;
  };

  productionModules = stdenv.mkDerivation {
    name = "npm-project-production-modules";
    src = filteredSrc;
    nativeBuildInputs = [ node ] ++ nativeBuildInputs;
    inherit buildInputs;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      ${npmSetup}
      ${npmInstall [
        "--omit=dev"
      ]}
      runHook postBuild
    '';
    # Every node_modules directory of the tree, at its place: the one at
    # the root, and those npm put inside workspaces for versions that could
    # not be hoisted.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      find . -name node_modules -type d -prune -print0 | while IFS= read -r -d "" dir; do
        mkdir -p "$out/$(dirname "$dir")"
        cp -a "$dir" "$out/$dir"
      done
      runHook postInstall
    '';
    # The links to the workspaces dangle here; each package replaces them
    # with installed copies.
    dontFixup = true;
  };

  # Package p installed the way a global `npm install` lays out a package:
  # lib/node_modules/<name> holds the package's files, and its production
  # dependencies lie beside it, where Node.js resolves them. The project's
  # own packages lie there as installed copies too, so a workspace that
  # depends on another finds it.
  mkPackage =
    p:
    stdenv.mkDerivation {
      pname = builtins.replaceStrings [ "@" "/" ] [ "" "-" ] p.name;
      inherit (p) version;
      outputs = [
        "out"
        "tarball"
      ];
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      # The commands' interpreter is this Node.js.
      buildInputs = [ node ];
      installPhase = ''
        runHook preInstall
        modules="$out/lib/node_modules"
        mkdir -p "$modules" "$tarball"
        cp ${build}/${lib.escapeShellArg (tarballName p)} "$tarball/package.tgz"
        if [ -d ${productionModules}/node_modules ]; then
          cp -a ${productionModules}/node_modules/. "$modules/"
          chmod -R u+w "$modules"
          rm -rf "$modules/.bin" "$modules/.package-lock.json"
        fi
        ${lib.concatMapStrings (o: ''
          rm -rf "$modules"/${lib.escapeShellArg o.name}
          mkdir -p "$modules"/${lib.escapeShellArg o.name}
          tar -xzf ${build}/${lib.escapeShellArg (tarballName o)} --strip-components=1 \
            -C "$modules"/${lib.escapeShellArg o.name}
          ${lib.optionalString (o.dir != "") ''
            if [ -d ${productionModules}/${lib.escapeShellArg o.dir}/node_modules ]; then
              cp -a ${productionModules}/${lib.escapeShellArg o.dir}/node_modules \
                "$modules"/${lib.escapeShellArg o.name}/node_modules
            fi
          ''}
        '') ownPackages}
        chmod -R u+w "$modules"
        ${lib.optionalString (p.bin != { }) ''mkdir -p "$out/bin"''}
        ${lib.concatStrings (
          lib.mapAttrsToList (command: file: ''
            target="$modules"/${lib.escapeShellArg p.name}/${lib.escapeShellArg file}
            chmod +x "$target"
            ln -s "$target" "$out/bin"/${lib.escapeShellArg command}
          '') p.bin
        )}
        runHook postInstall
      '';
      passthru = {
        inherit (p) name dir;
      };
      meta = lib.optionalAttrs (p.bin != { }) {
        mainProgram = builtins.head (builtins.attrNames p.bin);
      };
    };
in
{
  inherit dependencies build productionModules;
  packages = lib.mapAttrs (_: mkPackage) lock.packages;
}
