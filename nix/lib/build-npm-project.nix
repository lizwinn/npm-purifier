# SPDX-License-Identifier: MIT
#
# buildNpmProject: sandboxed builds of an npm project, from the
# package-lock.json at its root, and from the npm-purifier.lock.json that
# `npm-purifier lock` writes beside it when the project has git
# dependencies. The project needs no Nix files of its own: the lockfiles
# name every tarball and repository the install fetches, and every package
# of the project (the root, its workspaces and the local directories it
# depends on).
#
# Applied to the library of the npm-purifier flake, the file is a package
# for callPackage: the second argument set is what it takes from the
# package set, and the result is the builder. The flake's default overlay
# (`overlays.default`) adds the scope `npm-purifier` to the package set,
# and the scope holds the builder as `buildNpmProject`. A package written
# for callPackage takes the scope by name:
#
#   { npm-purifier }:
#   (npm-purifier.buildNpmProject { src = ./.; }).packages.my-app
#
# `npm-purifier.buildNpmProject.override` replaces what the builder takes,
# and `npm-purifier.overrideScope` replaces what everything in the scope
# shares.
#
# The builder returns
#
#   packages.<name>   package <name> of the project, installed with its
#                     production dependencies under lib/node_modules, with
#                     its commands in bin/; its `tarball` output holds
#                     package.tgz, the file `npm publish` uploads
#   tests             the project's `test` script, run after its build
#                     scripts
#   release           the tarballs `npm-purifier publish` uploads, one per
#                     package of the project, at <name>.tgz with the
#                     package name's `@` left out and its `/` as `__`
#   fetches           the entries of the purifier library that the build
#                     fetches: the locked tarballs and the git dependencies
#   cache             the content of npm's cache: every locked tarball, and
#                     the archives of git dependencies
#   productionModules the production dependencies (`npm ci --production`)
#   interactive       what `npm-purifier prefetch` builds for the `npm`
#                     wrapper
{
  # The library of the npm-purifier flake, with the purifier library and
  # `npm-purifier.readLock`.
  lib,
}:
{
  stdenv,
  runCommand,
  writeShellScript,
  writeText,
  runtimeShell,
  callPackage,
  git,
  nodejs,
  python3,
  nix,
}:
{
  # The source tree. It holds the project and every local directory the
  # project depends on.
  src,
  # Fetchers that replace those of the purifier library (fetchurl,
  # fetchgit), such as a fetchurl that sends credentials or reads a mirror.
  fetchers ? { },
  # Native repositories supplied by other purified Nix projects.
  dependencies ? lib.purifier.lockedProjectInputs {
    inputs =
      if builtins.pathExists lockFile then (lib.importJSON lockFile).projectInputs or [ ] else [ ];
    system = stdenv.hostPlatform.system;
  },
  # The directory of the project inside `src`, where package.json and
  # package-lock.json lie. The default is the root of `src`.
  projectDir ? "",
  # npm-purifier.lock.json, which `npm-purifier lock` writes for the git
  # dependencies; the default is the one at the project root. A packaging
  # flake keeps it outside `src` for a project its author does not change,
  # and the file then also completes the entries of package-lock.json
  # that lack a URL or an integrity.
  lockFile ? src + lib.optionalString (projectDir != "") "/${projectDir}" + "/npm-purifier.lock.json",
  # npm's lockfile; the default is the one in the project. A packaging
  # flake can keep its own copy outside the repository, which the build
  # installs from in place of the one in `src`.
  packageLock ? src + lib.optionalString (projectDir != "") "/${projectDir}" + "/package-lock.json",
  # The Node.js that runs npm and the project's scripts, and that the
  # packages' commands run on. Git dependencies with a prepare script need
  # the Node.js of nixpkgs, whose npm prepares them inside the sandbox.
  node ? nodejs,
  # Host graph tooling, independent of the selected project runtime.
  captureNode ? nodejs,
  # The package scripts that build the project, run in order before the
  # packages are packed. A script the root package defines runs at the
  # root; otherwise it runs in each workspace that defines it.
  buildScripts ? [ "build" ],
  # Makes the packages depend on `tests`, which runs the `test` script the
  # same way, after the build scripts.
  doCheck ? false,
  # Arguments for the `test` script, as `npm test -- <arguments>` passes
  # them.
  checkFlags ? [ ],
  # Tools the build scripts and the dependencies' install scripts need.
  # Python is there for node-gyp.
  nativeBuildInputs ? [ python3 ],
  # Libraries native addons link against.
  buildInputs ? [ ],
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
  inputSelection = lib.purifier.npmInputSelection { inherit dependencies; };
  selectedInputs = inputSelection.inputs;
  inputViews = writeText "npm-input-views.json" (builtins.toJSON inputSelection.views);

  # The lock in memory, which fails evaluation with the problems of the
  # lockfiles.
  lock = lib.purifier.checkLock (
    lib.npm-purifier.readLock {
      providedNames = inputSelection.names;
      providedVersions = inputSelection.versions;
      inherit
        src
        projectDir
        lockFile
        packageLock
        ;
    }
  );

  # npm installs offline only from entries with a URL and an integrity.
  # When an external npm-purifier.lock.json completes package-lock.json,
  # the install reads a completed copy, which the build writes. The lock
  # in memory has checked the file by then.
  completions = builtins.seq lock (
    if builtins.pathExists lockFile then (lib.importJSON lockFile).completions or { } else { }
  );
  completedPackageLock =
    let
      read = lib.importJSON packageLock;
      completeLegacy =
        prefix: dependencies:
        lib.mapAttrs (
          name: entry:
          let
            key = prefix + "node_modules/" + name;
          in
          entry
          // (completions.${key} or { })
          // lib.optionalAttrs (entry ? dependencies) {
            dependencies = completeLegacy (key + "/") entry.dependencies;
          }
        ) dependencies;
    in
    writeText "package-lock.json" (
      builtins.toJSON (
        read
        // (
          if (read.lockfileVersion or 1) == 1 then
            {
              dependencies = completeLegacy "" (read.dependencies or { });
            }
          else
            {
              packages = lib.mapAttrs (key: entry: entry // completions.${key} or { }) read.packages;
            }
        )
      )
    );

  # The package-lock.json npm installs from: the one in the project, a copy
  # given as `packageLock`, or that one completed.
  installLock =
    if completions != { } then
      completedPackageLock
    else if
      packageLock != src + lib.optionalString (projectDir != "") "/${projectDir}" + "/package-lock.json"
    then
      packageLock
    else
      null;

  cache = callPackage ./cache.nix {
    inherit fetchers gitCheckouts lock;
    inherit (lib) purifier;
  };

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !(
      (
        type == "directory"
        && builtins.elem name [
          "node_modules"
          ".npm-purifier"
        ]
      )
      || name == ".git"
      || lib.hasPrefix "result" name
    );

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

  # The file name of a package's tarball in `release`.
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
    ${lib.optionalString (dependencies != [ ]) ''
      export NPM_PURIFIER_INPUT_VIEWS=${inputViews}
      export NPM_PURIFIER_NPM_MODULES=${node}/lib/node_modules/npm/node_modules
      export NODE_OPTIONS="--require=${./npm-bindings.cjs} ''${NODE_OPTIONS:-}"
    ''}
    mkdir -p "$HOME" "$npm_config_cache/_cacache"
    cp -rs --no-preserve=mode ${cache.tree}/. "$npm_config_cache/_cacache"
    ${cache.environment}
    ${lib.optionalString (installLock != null) ''
      cp --no-preserve=mode ${installLock} package-lock.json
    ''}
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
      local script="$1"
      shift
      local extra=()
      if [ "$#" -gt 0 ]; then
        extra=(-- "$@")
      fi
      if node -e 'var scripts = require("./package.json").scripts; process.exit(scripts && scripts[process.argv[1]] ? 0 : 1)' "$script"; then
        npm run "$script" "''${extra[@]}"
      elif node -e 'process.exit(require("./package.json").workspaces ? 0 : 1)'; then
        npm run "$script" --workspaces --if-present "''${extra[@]}"
      fi
    }
  '';

  ownPackages = builtins.attrValues lock.outputs;

  inputs = [ node ] ++ lib.optional cache.needsGit git ++ nativeBuildInputs;

  release = stdenv.mkDerivation {
    outputs = [
      "out"
      "graph"
    ];
    name = "npm-project-release";
    passthru = { inherit projections; };
    src = filteredSrc;
    nativeBuildInputs = inputs ++ [ nix ];
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
      runHook postBuild
    '';
    # `npm pack` runs the packages' prepack, prepare and postpack scripts,
    # as `npm publish` does. It packs the root, and every other package of
    # the project from its directory.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      ${lib.concatMapStrings (p: ''
        (
          cd ${lib.escapeShellArg (if p.dir == "" then "." else "./${p.dir}")}
          # npm 6 predates --pack-destination. Pack in the package directory
          # with the selected native npm, retaining its lifecycle semantics.
          packed="$(npm pack | tail -n 1)"
          test "$(basename "$packed")" = "$packed"
          test -f "$packed"
          mv "$packed" "$out"/${lib.escapeShellArg (tarballName p)}
        )
      '') ownPackages}
      export NPM_PURIFIER_NPM_MODULES=${captureNode}/lib/node_modules/npm/node_modules
      export NPM_PURIFIER_TARGET_NODE=${node}/bin/node
      export NPM_PROJECTION_NIX=${nix}/bin/nix
      ${captureNode}/bin/node ${lib.purifier.npmCaptureTool} "$PWD" "$out" "$graph" \
        ${writeText "npm-projection-packages.json" (builtins.toJSON ownPackages)}
      runHook postInstall
    '';
    # The tarballs are what npm publishes, byte for byte.
    dontFixup = true;
  };

  # The project's tests, after the build scripts. Tests often run the
  # project's own scripts, whose `#!/usr/bin/env` lines find no interpreter
  # in the sandbox, so the test run gives every script of its copy of the
  # source an absolute interpreter first. It runs apart from `release`,
  # whose tarballs keep the files as the project has them.
  tests = stdenv.mkDerivation {
    name = "npm-project-tests";
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
      patchShebangs "$srcRoot" > /dev/null
      runScript test ${lib.escapeShellArgs checkFlags}
      runHook postBuild
    '';
    installPhase = ''
      touch "$out"
    '';
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
        "--production"
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
      # With doCheck, a package exists only once the project's tests pass.
      ${if doCheck then "tested" else null} = tests;
      installPhase = ''
        runHook preInstall
        modules="$out/lib/node_modules"
        mkdir -p "$modules" "$tarball"
        cp ${release}/${lib.escapeShellArg (tarballName p)} "$tarball/package.tgz"
        if [ -d ${projectModules}/node_modules ]; then
          cp -a ${projectModules}/node_modules/. "$modules/"
          chmod -R u+w "$modules"
          rm -rf "$modules/.bin" "$modules/.package-lock.json"
        fi
        ${lib.concatMapStrings (o: ''
          rm -rf "$modules"/${lib.escapeShellArg o.name}
          mkdir -p "$modules"/${lib.escapeShellArg o.name}
          tar -xzf ${release}/${lib.escapeShellArg (tarballName o)} --strip-components=1 \
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
        projections = projectionFor [ p.name ];
      };
      meta = lib.optionalAttrs (p.bin != { }) {
        mainProgram = builtins.head (builtins.attrNames p.bin);
      };
    };
  projectionFor =
    roots:
    lib.purifier.npmProjections {
      graph = "${release.graph}/graph.json";
      archives = "${release.graph}/archives";
      producer = release;
      inherit
        roots
        runCommand
        python3
        dependencies
        ;
    };
  projections = projectionFor null;
in
{
  inherit
    release
    tests
    productionModules
    projections
    ;
  fetches = lock.entries;
  cache = cache.tree;
  packages = lib.mapAttrs (_: mkPackage) lock.outputs;
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
        ${lib.optionalString (dependencies != [ ]) ''
          cat >> "$out/environment" <<'NPM_INPUT_ENV'
          export NPM_PURIFIER_INPUT_VIEWS=${inputViews}
          export NPM_PURIFIER_NPM_MODULES=${node}/lib/node_modules/npm/node_modules
          export NODE_OPTIONS="--require=${./npm-bindings.cjs} ''${NODE_OPTIONS:-}"
          NPM_INPUT_ENV
          mkdir -p "$out/nix-support"
          printf '%s\n' ${
            lib.escapeShellArgs (
              lib.concatMap (input: [
                (toString input.producer)
                (toString input.repository)
              ]) selectedInputs
            )
          } > "$out/nix-support/inputs"
        ''}
      '';
}
