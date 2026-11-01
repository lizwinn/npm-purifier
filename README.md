# npm-purifier

npm-purifier builds npm projects in the Nix sandbox from their
`package-lock.json`. The lockfile already names every tarball the
install needs, with its URL and integrity hash, so the project needs no
generated Nix files and no lockfile beyond the one npm writes.

- **Sandboxed builds.** `buildNpmProject`, which the flake's overlay adds
  to a package set, reads the lockfile at evaluation time. Nix fetches each
  tarball by its integrity hash, and npm installs them offline: `npm ci`,
  the dependencies' install scripts, the project's build script and
  `npm pack`.
- **One package per package of the project.** The root package and each
  workspace become `packages.<name>`, installed with their production
  dependencies and with their commands in `bin/`. The `tarball` output of
  each holds `package.tgz`, the file `npm publish` uploads.
- **npm on the locked tarballs.** The flake's `npm` wrapper builds a
  project's locked tarballs into a cache through Nix and runs npm against
  it, offline, so `npm ci`, `npm run` and `npm test` read only what the
  lockfile names.

## How it works

npm keeps downloaded tarballs in a content-addressed cache and finds a
tarball there by its integrity hash. The path of a tarball in the cache
follows from the hash alone (`_cacache/content-v2/sha512/<hex>`), so Nix
computes each path from `package-lock.json` during evaluation, fetches the
tarballs as fixed-output downloads, and lays them out as the cache. npm
running with `offline` set then installs from that cache and never
contacts the registry.

Optional packages for other platforms, such as the per-platform binaries
of esbuild, stay out of the fetch, as npm leaves them out of the install.

## Use

The flake's `overlays.default` adds `buildNpmProject` to a package set,
and a package written for `callPackage` takes it by name, like any other
builder:

```nix
# package.nix
{ buildNpmProject }:
(buildNpmProject { src = ./.; }).packages.my-app
```

```nix
{
  inputs.npm-purifier.url = "github:nix-purifiers/npm-purifier";
  inputs.nixpkgs.follows = "npm-purifier/nixpkgs";

  outputs = { nixpkgs, npm-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          npm-purifier.overlays.default
          (final: prev: { my-app = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.default = pkgs.my-app;
    };
}
```

`nix build` builds the package, and `nix build '.#default.tarball'`
builds the tarball to publish:

```zsh
npm publish "$(nix build '.#default.tarball' --print-out-paths)/package.tgz"
```

`nix/lib/build-npm-project.nix` documents the builder's arguments:

- `node` is the Node.js that runs npm and the packages' commands. The
  default is the package set's `nodejs`.
- `buildScripts` lists the package scripts that build the project. The
  default is `[ "build" ]`. A script the root package defines runs at the
  root. Otherwise it runs in each workspace that defines it.
- `doCheck` runs the `test` script the same way.
- `nativeBuildInputs` and `buildInputs` give build scripts and native
  addons their tools and libraries. The default `nativeBuildInputs` is
  Python, for node-gyp.
- `lockFile`, `fetchurl` and `srcFilter` replace the lockfile, the
  tarball fetcher and the source filter.

Besides `packages`, the builder returns `dependencies` (the cache content),
`build` (the packed tarballs) and `productionModules` (the result of
`npm ci --omit=dev`).

## Interactive use

```zsh
nix run github:nix-purifiers/npm-purifier -- ci
```

runs `npm ci` with the project's locked tarballs from the Nix store.
`nix develop github:nix-purifiers/npm-purifier` gives a shell where `npm`
is the wrapper. The wrapper finds the nearest `package-lock.json` above the
current directory, builds its tarballs under
`$XDG_CACHE_HOME/npm-purifier` with a GC root there, and runs npm against
them with `offline` set. It rebuilds that cache when the lockfile changes.

The commands that change the lockfile (`install`, `update`, `uninstall`
and their aliases) resolve against the registry as usual. To change
dependencies, run `npm install`, and the next command reads the new
lockfile. `NPM_PURIFIER=0` turns the wrapper off for any command.

## Limits

- Dependencies from git repositories fail evaluation with a message that
  names them. npm-purifier fetches registry and http(s) tarballs, and
  tarballs inside the project (`file:` specs).
- An install script that downloads files itself, such as the browser
  download of Puppeteer, fails in the sandbox.
- A root package that declares workspaces and has no commands of its own
  is not one of the packages: it only coordinates the workspaces.
- Each package carries the production dependencies of the whole project,
  not only its own.

## Related work

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).
nixpkgs' `importNpmLock` also fetches each package of a
`package-lock.json` separately. npm-purifier differs in feeding npm its
own cache, so that the install, the build scripts and `npm pack` run as
npm runs them outside Nix.
