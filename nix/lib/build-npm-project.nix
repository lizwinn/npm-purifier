# SPDX-License-Identifier: MIT
#
# buildNpmProject: sandboxed builds of an npm project, from the
# package-lock.json at its root, and from the npm-purifier.lock.json that
# `npm nix-lock` writes beside it when the project has git dependencies.
# The project needs no Nix files of its own: the lockfiles name every
# tarball and repository the install fetches, and every package of the
# project (the root, its workspaces and the local directories it depends
# on).
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
#   cache             the content of npm's cache: every locked tarball, and
#                     the archives of git dependencies
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
  runCommand,
  writeShellScript,
  runtimeShell,
  nodejs,
  python3,
  git,
  # The shared purifier library, which the flake's overlay passes.
  purifier,
}:
{
  # The source tree. It holds the project and every local directory the
  # project depends on.
  src,
  # The directory of the project inside `src`, where package.json and
  # package-lock.json lie. The default is the root of `src`.
  projectDir ? "",
  # The lockfile; the default is the one npm writes at the project root.
  lockFile ? src + lib.optionalString (projectDir != "") "/${projectDir}" + "/package-lock.json",
  # The lockfile of the git dependencies, which `npm nix-lock` writes
  # beside package-lock.json.
  purifierLockFile ? dirOf lockFile + "/npm-purifier.lock.json",
  # The Node.js that runs npm and the project's scripts, and that the
  # packages' commands run on. Git dependencies with a prepare script need
  # the Node.js of nixpkgs, whose npm prepares them inside the sandbox.
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
  # Checkouts that replace the fetches of git dependencies, by their
  # `resolved` in the lockfile: for a repository the sandbox cannot reach,
  # such as a private one, a checkout fetched with the user's credentials
  # (builtins.fetchGit). A dependency npm downloads as an archive (from
  # GitHub, GitLab, Bitbucket or sourcehut) takes a plain checkout; one npm
  # clones takes a repository that holds the commit, with its submodules
  # checked out.
  gitCheckouts ? { },
  # Filters the source tree before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out installed
  # dependencies, version control and Nix result links.
  srcFilter ? null,
}:
let
  cache = callPackage ./cache.nix {
    inherit
      lockFile
      purifierLockFile
      fetchurl
      gitCheckouts
      purifier
      ;
  };
  inherit (cache) lock;

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

  # A directory relative to the project root, as a path relative to the
  # root of `src`. A local package outside `src` cannot take part in the
  # build.
  inSrc =
    dir:
    let
      parts = lib.filter (p: p != "" && p != ".") (lib.splitString "/" "${projectDir}/${dir}");
      step =
        acc: p:
        if p != ".." then
          acc ++ [ p ]
        else if acc == [ ] then
          throw "npm-purifier: the local package ${dir} lies outside src; pass a src that contains it and the project's directory inside it as projectDir."
        else
          lib.init acc;
    in
    lib.concatStringsSep "/" (lib.foldl' step [ ] parts);

  # The file name of a package's tarball in `build`.
  tarballName = p: (builtins.replaceStrings [ "@" "/" ] [ "" "__" ] p.name) + ".tgz";

  # The setup shared by every build: npm runs offline against a cache whose
  # content is the locked tarballs and git archives. npm writes index
  # entries, logs and the tarballs `npm pack` makes into the cache, so the
  # cache is a writable tree of links to the store. The build starts at
  # the root of `src` and works in the project's directory; `srcRoot`
  # names the root.
  npmSetup = ''
    srcRoot="$PWD"
    cd ${lib.escapeShellArg (if projectDir == "" then "." else projectDir)}
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
    cp -rs --no-preserve=mode ${cache.tree}/. "$npm_config_cache/_cacache"
    ${cache.environment}
  '';

  # npm runs every package script as `<script-shell> -c <command>`, with
  # the node_modules/.bin directory of each directory upwards on PATH. The
  # sandbox has no /usr/bin/env, so this shell gives the commands in those
  # directories absolute interpreters before it runs the script. The
  # install cannot patch them all beforehand: npm prepares git
  # dependencies while it installs, in directories of its own.
  scriptShell = writeShellScript "npm-purifier-script-shell" ''
    dir="$PWD"
    while :; do
      for bin in "$dir"/node_modules/.bin/*; do
        [ -e "$bin" ] || continue
        target="$(readlink -f "$bin")"
        IFS= read -r first < "$target" || continue
        case "$first" in
          "#!/usr/bin/env "*)
            interpreter="''${first#\#!/usr/bin/env }"
            interpreter="''${interpreter%% *}"
            if absolute="$(command -v "$interpreter")"; then
              sed -i "1s|^#!/usr/bin/env $interpreter|#!$absolute|" "$target"
            fi
            ;;
        esac
      done
      [ "$dir" = / ] && break
      dir="$(dirname "$dir")"
    done
    exec ${runtimeShell} "$@"
  '';

  # Installs the locked dependencies and runs their install scripts. npm
  # prepares git dependencies during the install only when scripts run.
  npmInstall = flags: ''
    export npm_config_script_shell=${scriptShell}
    npm ci ${lib.escapeShellArgs flags}
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

  inputs = [ node ] ++ lib.optional cache.needsGit git ++ nativeBuildInputs;

  build = stdenv.mkDerivation {
    name = "npm-project-build";
    src = filteredSrc;
    nativeBuildInputs = inputs;
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
    # as `npm publish` does. It packs the root, and every other package of
    # the project from its directory.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      ${lib.concatMapStrings (p: ''
        packdir="$(mktemp -d)"
        npm pack --pack-destination "$packdir" ${
          lib.optionalString (p.dir != "") (lib.escapeShellArg "./${p.dir}")
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
    nativeBuildInputs = inputs;
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
    # Every node_modules directory of the source tree, at its place
    # relative to the root of `src`: the one of the project, and those npm
    # put inside workspaces and local packages for versions that could not
    # be hoisted.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cd "$srcRoot"
      find . -name node_modules -type d -prune -print0 | while IFS= read -r -d "" dir; do
        mkdir -p "$out/$(dirname "$dir")"
        cp -a "$dir" "$out/$dir"
      done
      runHook postInstall
    '';
    # The links to the project's own packages dangle here; each package
    # replaces them with installed copies.
    dontFixup = true;
  };

  projectModules = productionModules + lib.optionalString (projectDir != "") "/${inSrc ""}";

  # Package p installed the way a global `npm install` lays out a package:
  # lib/node_modules/<name> holds the package's files, and its production
  # dependencies lie beside it, where Node.js resolves them. The project's
  # own packages lie there as installed copies too, so a package that
  # depends on another one of them finds it.
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
        if [ -d ${projectModules}/node_modules ]; then
          cp -a ${projectModules}/node_modules/. "$modules/"
          chmod -R u+w "$modules"
          rm -rf "$modules/.bin" "$modules/.package-lock.json"
        fi
        ${lib.concatMapStrings (o: ''
          rm -rf "$modules"/${lib.escapeShellArg o.name}
          mkdir -p "$modules"/${lib.escapeShellArg o.name}
          tar -xzf ${build}/${lib.escapeShellArg (tarballName o)} --strip-components=1 \
            -C "$modules"/${lib.escapeShellArg o.name}
          ${lib.optionalString (o.dir != "") ''
            if [ -d ${productionModules}/${lib.escapeShellArg (inSrc o.dir)}/node_modules ]; then
              cp -a ${productionModules}/${lib.escapeShellArg (inSrc o.dir)}/node_modules \
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
  inherit build productionModules;
  cache = cache.tree;
  packages = lib.mapAttrs (_: mkPackage) lock.packages;
  # What the `npm` wrapper builds for the project: the content of npm's
  # cache in `cache/`, and the shell commands that set up the environment
  # npm runs in, in `environment`. The Node.js of nixpkgs prepares git
  # dependencies with the patchShebangs of stdenv, which it loads from
  # $stdenv/setup.
  interactive =
    runCommand "npm-purifier-interactive"
      {
        passAsFile = [ "environment" ];
        environment = ''
          export stdenv=${stdenv}
          ${cache.environment}
        '';
      }
      ''
        mkdir -p "$out"
        ln -s ${cache.tree} "$out/cache"
        cp "$environmentPath" "$out/environment"
      '';
}
