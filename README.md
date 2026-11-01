# npm-purifier

npm-purifier builds npm projects in the Nix sandbox from their
`package-lock.json`. The lockfile already names every registry tarball
the install needs, with its URL and integrity hash, and every package the
project produces, so the project needs no generated Nix files. Git
dependencies are the one source npm does not pin by hash; for those, a
lock run writes `npm-purifier.lock.json` beside `package-lock.json`.

- **Sandboxed builds.** `buildNpmProject`, which the flake's overlay adds
  to a package set, reads the lockfiles at evaluation time. Nix fetches
  every tarball and repository, and npm installs, prepares, builds and
  packs the project offline: `npm ci` with the dependencies' install
  scripts, the project's build script and `npm pack`.
- **One output per package.** The root package, each workspace and each
  local directory the project depends on become `packages.<name>`,
  installed with their production dependencies and with their commands in
  `bin/`. The `tarball` output of each holds `package.tgz`, the file
  `npm publish` uploads.
- **npm on the locked dependencies.** The flake's `npm` wrapper builds a
  project's dependencies into a cache through Nix and runs npm against it,
  offline, so `npm ci`, `npm run` and `npm test` read only what the
  lockfiles name.
- **Publishing what Nix built.** `npm nix-publish` builds the package in
  the current directory with Nix and publishes that tarball.

## How it works

npm keeps downloaded tarballs in a content-addressed cache and finds a
registry tarball there by its integrity hash. The path of a tarball in the
cache follows from the hash alone (`_cacache/content-v2/sha512/<hex>`), so
Nix computes each path from `package-lock.json` during evaluation, fetches
the tarballs as fixed-output downloads, and lays them out as the cache.
npm, running with `offline` set, installs from that cache and never
contacts the registry. Optional packages for other platforms, such as the
per-platform binaries of esbuild, stay out of the fetch, as npm leaves them
out of the install. `package-lock.json` lists them for every platform, so
one lockfile serves every system.

npm skips the integrity of a git dependency and fetches it again on every
install, in one of two ways:

- From GitHub, GitLab, Bitbucket or sourcehut, npm downloads the host's
  archive of the commit through its HTTP cache. Nix fetches the commit,
  packs the archive, and writes the cache index entry that answers the
  archive's URL with it.
- From any other repository, npm clones it with git, checks out the
  commit and updates its submodules. Nix fetches a plain checkout with its
  submodules, whose hash is stable, and the build makes each repository
  from that checkout and the raw commit object the lock run recorded. It
  writes the checkout as the commit's tree, writes the commit, checks that
  the commit's ID is the locked one, and marks the repository shallow at
  that commit. Git settings in the build map the repository's URL and each
  submodule's URL to the repositories made this way.

npm prepares a git dependency that has a prepare, build or install
script: it installs the dependency's own dependencies, dev dependencies
included, and runs the scripts before packing it. The Node.js of nixpkgs
does that preparation with `npm ci` in the build, which needs a lockfile
inside the dependency. The lock run takes the dependency's lockfile from
its repository, or makes one with `npm install --package-lock-only` when
the repository has none, and the build places it.

## The lock run

```zsh
npm nix-lock
```

writes `npm-purifier.lock.json` for the git dependencies of
`package-lock.json`. For each one it records the commit as a Nix hash of
its checkout, the archive URL or the repository and submodule URLs npm
uses, the raw commit objects of a repository npm clones and of its
submodules, and the lockfile npm installs to prepare it. It reuses the entries
it has, since an entry names a commit, and removes the file when the
project has no git dependencies. The wrapper runs it after every command
that changes `package-lock.json` (`install`, `update`, `uninstall` and
their aliases), so the two files stay in step. Commit both.

A build whose `npm-purifier.lock.json` is missing, or was made for another
`package-lock.json`, fails evaluation and names the command to run.

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
builds the tarball to publish.

`nix/lib/build-npm-project.nix` documents the builder's arguments:

- `projectDir` names the project's directory inside `src`. A project that
  depends on a local directory outside its own directory
  (`"file:../shared"`) builds from a `src` that holds both.
- `node` is the Node.js that runs npm and the packages' commands. The
  default is the package set's `nodejs`. Git dependencies that npm
  prepares need the Node.js of nixpkgs, whose npm prepares them inside the
  sandbox.
- `buildScripts` lists the package scripts that build the project. The
  default is `[ "build" ]`. A script the root package defines runs at the
  root. Otherwise it runs in each workspace that defines it.
- `doCheck` runs the `test` script the same way.
- `nativeBuildInputs` and `buildInputs` give build scripts and native
  addons their tools and libraries. The default `nativeBuildInputs` is
  Python, for node-gyp.
- `gitCheckouts` supplies checkouts for git dependencies by their
  `resolved` in the lockfile, in place of the fetch. A private repository,
  which the sandbox cannot reach, takes a checkout fetched with the user's
  credentials (`builtins.fetchGit`).
- `lockFile`, `purifierLockFile`, `fetchurl` and `srcFilter` replace the
  lockfiles, the tarball fetcher and the source filter.

Besides `packages`, the builder returns `cache` (the content of npm's
cache), `build` (the packed tarballs) and `productionModules` (the result
of `npm ci --omit=dev`).

## Interactive use

```zsh
nix run github:nix-purifiers/npm-purifier -- ci
```

runs `npm ci` with the project's dependencies from the Nix store.
`nix develop github:nix-purifiers/npm-purifier` gives a shell where `npm`
is the wrapper. The wrapper finds the nearest `package-lock.json` above the
current directory, builds the project's cache under
`$XDG_CACHE_HOME/npm-purifier` with a GC root there, and runs npm against
it with `offline` set. It rebuilds that cache when a lockfile changes.

The commands that change the lockfile resolve against the registry as
usual and then run the lock run. `NPM_PURIFIER=0` turns the wrapper off for
any command.

## Publishing

```zsh
npm nix-publish
```

builds the package in the current directory with Nix, as
`packages.<name>.tarball`, and runs `npm publish` on that tarball. Further
arguments go to `npm publish`, so `npm nix-publish --dry-run` shows what
would be published, and `--tag`, `--access` and the registry settings work
as they do for `npm publish`. Nothing is packed outside the sandbox.

## Decisions

- A root package that declares workspaces and has no commands of its own
  is not an output: it only coordinates the workspaces.
- Each package carries the production dependencies of the whole project,
  installed beside it under `lib/node_modules`, rather than only its own.
  npm hoists a project's dependencies into one tree, and splitting that
  tree per package would resolve them a second time.
- The build runs the dependencies' install scripts during `npm ci`, as npm
  does, rather than afterwards. npm prepares git dependencies only when
  scripts run. The sandbox has no `/usr/bin/env`, so the shell npm runs
  scripts with gives the commands on `PATH` absolute interpreters first.

## Limits

- An install script that downloads files itself, such as the browser
  download of Puppeteer, fails in the sandbox: the download is not in any
  lockfile, and the sandbox has no network.
- A git dependency from a private repository cannot be fetched in the
  sandbox, which has no credentials. Supply its checkout with
  `gitCheckouts`.
- A repository that npm clones is made again from its checkout, so the
  checkout has to give the commit's tree back. A repository whose
  `.gitattributes` changes file contents on checkout in a way `git add`
  does not reverse fails the build with a message that names the commit.
- The flake builds for x86_64-linux and aarch64-linux.

## Related work

npm-purifier follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier): the tool
keeps planning the build, its lockfile names every download, and Nix
builds from the lockfile with no generated Nix files. The purifier idea
was inspired by nixcloud's [cargo (libnix)](https://github.com/nixcloud/cargo).
nixpkgs' `importNpmLock` also fetches each package of a
`package-lock.json` separately, and the Node.js of nixpkgs carries the
preparation of git dependencies that this builder relies on.
