# npm-purifier

npm-purifier builds npm projects in the Nix sandbox from their
`package-lock.json`, and runs npm on the developer's machine against the
same locked dependencies, offline. The lockfile already names every
registry tarball with its URL and integrity hash, and Nix reads it at
evaluation time, so the project needs no generated Nix files. Git
dependencies are the one source npm does not pin by a hash Nix can use.
For those, `npm-purifier lock` writes `npm-purifier.lock.json` beside
`package-lock.json`, and a project without git dependencies has no such
file.

## Quickstart

In the project's directory, enter a shell with the `npm` wrapper and the
`npm-purifier` command, then lock and install:

```zsh
nix develop github:nix-purifiers/npm-purifier
npm-purifier lock
npm ci
```

Commit `package-lock.json`, and `npm-purifier.lock.json` when the lock
run writes one. Add `.npm-purifier/` to `.gitignore`: it holds the
project's prefetched dependencies.

To build the project with Nix, call the builder from the flake's library
with a package set:

```nix
{
  inputs.npm-purifier.url = "github:nix-purifiers/npm-purifier";
  inputs.nixpkgs.follows = "npm-purifier/nixpkgs";

  outputs = { nixpkgs, npm-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      project = npm-purifier.lib.npm-purifier.buildNpmProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.${system} = {
        default = project.packages.my-app;
        release = project.release;
      };
      checks.${system}.tests = project.tests;
    };
}
```

The root package, each workspace and each local directory the project
depends on become `packages.<name>`, installed with their production
dependencies and with their commands in `bin/`. `release` holds the
tarballs `npm publish` uploads, and `tests` runs the `test` script in a
derivation of its own. `fetches` lists every download as an entry of the
purifier library, for SBOM, license and vulnerability tools.
`nix/lib/build-npm-project.nix` documents every argument of the builder.

`npm-purifier.lib.npm-purifier.readLock { src = ./.; }` reads the
lockfiles without building anything. It returns the downloads as
`entries`, the packages as `outputs`, and, in `problems`, each reason the
lockfiles cannot be used, which is the same shape every purifier returns.

## Everyday loop

The `npm` wrapper passes every command to npm. The commands that change
the lockfile (`install`, `update`, `uninstall` and their aliases) resolve
against the registry as npm does, and then run `npm-purifier lock`, so
`npm-purifier.lock.json` stays in step with `package-lock.json`. Every
other command (`ci`, `run`, `test`, `exec`) runs offline against the
dependencies Nix prefetched.

`npm-purifier lock` does three things:

- It runs `npm install --package-lock-only`, which brings
  `package-lock.json` in step with `package.json`.
- It records the URL and integrity of lockfile entries that lack them, as
  a later `npm install` would. Some lockfiles leave both out, and npm then
  asks the registry at install time.
- It writes `npm-purifier.lock.json` for the git dependencies, or removes
  it when the project has none.

`npm-purifier lock` keeps the versions `package-lock.json` resolves.
`npm-purifier update` moves them: it runs `npm update` on every
dependency, or on the packages named after it, and then locks as
`npm-purifier lock` does, so both lockfiles change in one run.

`npm-purifier publish` builds the package in the current directory with
Nix and runs `npm publish` on that tarball. Further arguments go to
`npm publish`, so `npm-purifier publish --dry-run` shows what would be
uploaded. Nothing is packed outside the sandbox.

On the examples below, `npm-purifier lock` with nothing to change took
under a second, and an offline `npm ci` took 3 seconds for commander and 18
seconds for http-server.

## Offline work

`npm-purifier prefetch` builds the npm cache of every locked tarball and
git dependency in the Nix store, with a garbage-collector root at
`.npm-purifier/dependencies`. The wrapper runs it on its own when either
lockfile changed since the last prefetch. After the prefetch, the
wrapper runs npm with `offline` set and a registry that nothing needs to
answer: `npm ci`, the build scripts and the tests read only what the
lockfiles name.

A command that needs a download the lockfiles do not name stops with
npm's `ENOTCACHED` error, and the wrapper adds a line that names
`npm-purifier lock`. `NPM_PURIFIER=0` turns the wrapper off for one
command. `NPM_PURIFIER_LOCKFILE` names an `npm-purifier.lock.json` other
than the one at the project root, for the wrapper and for every
`npm-purifier` command. A flake that keeps the file outside the project
can set it in its development shell to the path it passes the builder as
`lockFile`.

An external build leaves `package-lock.json` as the project has it. When
that file leaves out the URL or integrity of entries, the external
`npm-purifier.lock.json` records them for the Nix build, and npm, which
reads only `package-lock.json`, cannot install those entries offline. The
wrapper then stops with `ENOTCACHED` and says so. The offline loop of such
a project needs the entries completed in `package-lock.json` itself,
which `npm-purifier lock` does when `npm-purifier.lock.json` lies in the
project.

## Editor

Editors and language servers read `node_modules`, which `npm ci` through
the wrapper fills as plain npm does, so they need no setup of their own.
An editor that runs npm itself (task runners, script panels) gets the
wrapper when it starts from the `nix develop` shell, or from a direnv
`use flake` of a flake whose development shell includes the wrapper.

## Errors and fixes

The builder checks the lockfiles at evaluation time and stops with a
message that names the fix. `readLock` lists the same messages in
`problems`.

| Message | Cause | Fix |
| --- | --- | --- |
| `has git dependencies, and npm-purifier.lock.json does not exist` | a git dependency and no `npm-purifier.lock.json` | run `npm-purifier lock` and commit the file |
| `was made for another package-lock.json` | `package-lock.json` changed without the wrapper | run `npm-purifier lock` |
| `has no entry for <resolved>` | a git dependency the lock run has not seen | run `npm-purifier lock` |
| `was changed after npm-purifier lock wrote it` | `npm-purifier.lock.json` was edited by hand | run `npm-purifier lock` |
| `is not of format version 3` | a file from an older npm-purifier | run `npm-purifier lock` |
| `has no resolved URL` or `has no integrity` | an incomplete lockfile entry | run `npm-purifier lock` |
| `run npm install with npm 7 or newer` | a lockfile of npm 6 | run `npm install` with a current npm |
| `has merge conflict markers` | an unresolved merge in a lockfile | resolve it, then run `npm-purifier lock` |
| `seems to be corrupted` (from npm) | a tarball whose content does not match its integrity | check the URL and the integrity in `package-lock.json` |

## Sources supported and refused

npm-purifier serves these sources:

- Registry tarballs from any registry, by the URL and integrity in
  `package-lock.json`. Optional packages for other platforms stay out of
  the fetch, as npm leaves them out of the install, so one lockfile serves
  every system.
- Git dependencies on GitHub, GitLab, Bitbucket and sourcehut, which npm
  downloads as the host's archive of the commit. Nix fetches the commit,
  packs the archive and adds the cache entry that answers its URL.
- Git dependencies from any other repository, with their submodules. npm
  clones these, so the build makes each repository again from a plain
  checkout and the raw commit object the lock run recorded, and checks the
  commit's ID.
- Git dependencies that npm prepares (one with a prepare, build or install
  script). The lock run records the lockfile npm installs before the
  script runs.
- Workspaces, and local directories and tarballs (`file:`), including
  directories outside the project when `src` holds them.

npm-purifier refuses these:

- An install script that downloads files itself, such as the browser
  download of Puppeteer, fails in the sandbox, because no lockfile names
  the download.
- A git dependency from a private repository cannot be fetched in the
  sandbox. The builder's `gitCheckouts` argument supplies its checkout
  instead.
- A git dependency that npm clones from a URL other than the one in its
  `resolved` stops the lock run, which asks for the dependency in the
  `git+<url>#<commit>` form.
- A lockfile of npm 6 (`lockfileVersion` 1) stops the evaluation.

`npm-purifier.lock.json` holds only what `package-lock.json` cannot
supply. Per git dependency, keyed by its `resolved`, it holds the Nix hash
of the checkout, which npm does not record. For a hosted repository it
adds the archive URL and the URL to fetch the checkout from, which npm's
rules for the host decide. For a cloned repository it adds whether there
are submodules, the raw commit objects, and the URL and commit of each
submodule, which live in the repository itself. For a prepared dependency
it adds the dependency's own lockfile. The commit and the directory in the
repository come from `resolved`.

A flake can package a project without changing it. An external build
leaves `package-lock.json` untouched, and what it lacks goes into the
external `npm-purifier.lock.json`. The project's
`package-lock.json` stays in the tree, and the flake keeps
`npm-purifier.lock.json` outside it and passes that path to the builder
as `lockFile`. `npm-purifier lock --lockfile <path>` then leaves the
project's files as they are. When `package-lock.json` leaves out the URL
or integrity of entries, the lock run records them in the `completions`
of that external file, keyed by their place in `package-lock.json`. The
build installs from a copy of `package-lock.json` completed with them.

## Examples

The flake's checks lock and build real projects from pinned sources, as
examples of npm-purifier at work. These two show its builder and its
offline loop:

- [tj/commander.js](https://github.com/tj/commander.js): the build runs the
  type checks, and all 1372 tests of its suite pass. Upgrading prettier
  through the wrapper took 2 seconds plus the lock run, and the next
  offline `npm ci` took 7 seconds.
- [http-party/http-server](https://github.com/http-party/http-server): the
  lockfile left out the URL and integrity of 130 entries. That is why the
  lock run completes such entries. The check builds it as a packaging
  flake would, with its upstream tree unchanged and an external
  `npm-purifier.lock.json` that holds the 130 completions. Its tests run
  with `--jobs=1`, because
  parallel test files race for port 8000, which is why the builder takes
  `checkFlags`. All 532 assertions of its suite pass.

The tests run in a derivation of their own, so a package does not rebuild
when only its tests change.

## Credits

npm-purifier follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier): the build
tool keeps planning the build, its lockfile names every download, and Nix
builds from the lockfile with no generated Nix files. The idea of a
purifier was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo). The Node.js of
nixpkgs carries the patch to pacote, npm's fetcher, that prepares git
dependencies inside the sandbox, and nixpkgs' `importNpmLock` also fetches
each package of a `package-lock.json` separately.
