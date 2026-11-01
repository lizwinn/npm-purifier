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

We recommend committing both lockfiles to the project's repository:
`package-lock.json`, and `npm-purifier.lock.json` when the lock run writes
one. The builder and the commands look for them there by default. Add
`.npm-purifier/` to `.gitignore`: it holds the project's prefetched
dependencies.

To build the project with Nix, run this in the project's directory. It adds
no Nix file to the project. The overlay of the flake adds one attribute to
the package set, the scope `npm-purifier`, which holds the builder
`buildNpmProject` beside the commands:

```zsh
nix build --impure --expr '
  let
    purifier = builtins.getFlake "github:nix-purifiers/npm-purifier";
    pkgs = import purifier.inputs.nixpkgs {
      system = builtins.currentSystem;
      overlays = [ purifier.overlays.default ];
    };
  in
  (pkgs.npm-purifier.buildNpmProject { src = ./.; }).packages.my-app'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

The root package, each workspace and each local directory the project
depends on become `packages.<name>`, installed with their production
dependencies and with their commands in `bin/`. `release` holds the
tarballs `npm publish` uploads, and `tests` runs the `test` script in a
derivation of its own. `fetches` lists every download as an entry of the
purifier library, for SBOM, license and vulnerability tools.
`nix/lib/build-npm-project.nix` documents every argument of the builder.

A project whose authors want a flake can package it with one that calls the
builder directly. The flake can live in the repository of the project or in
another one:

```nix
{
  inputs.npm-purifier.url = "github:nix-purifiers/npm-purifier";
  inputs.nixpkgs.follows = "npm-purifier/nixpkgs";

  outputs = { nixpkgs, npm-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ npm-purifier.overlays.default ];
      };
      project = pkgs.npm-purifier.buildNpmProject { src = ./.; };
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

A package in a package set that has the overlay applied takes the scope by
name:

```nix
{ npm-purifier }: (npm-purifier.buildNpmProject { src = ./.; }).packages.my-app
```

`npm-purifier.buildNpmProject.override` replaces the packages the builder
takes, such as the `nodejs` its packages run on, and
`npm-purifier.overrideScope` replaces what everything in the scope
shares.

`npm-purifier.lib.npm-purifier.readLock { src = ./.; }` reads the
lockfiles without building anything. It returns the downloads as
`entries`, the packages as `outputs`, and, in `problems`, each reason the
lockfiles cannot be used, which is the same shape every purifier returns.

## Development loop

The purifier contract runs the development loop through the build tool's
own command. npm has no plugin mechanism through which npm-purifier could
give that command the locked downloads, so the loop runs through the
`npm` wrapper that `nix develop github:nix-purifiers/npm-purifier` puts on
`PATH`. The wrapper takes npm's own commands and arguments.

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

## Working offline

`npm-purifier prefetch` builds the npm cache of every locked tarball and
git dependency in the Nix store, with a garbage-collector root at
`.npm-purifier/dependencies` in the project. The contract puts that root
beside the purifier lockfile. npm-purifier keeps it in the project even
when `npm-purifier.lock.json` lies outside, because npm reads its cache
from there. The wrapper runs `prefetch` on its own when either
lockfile changed since the last prefetch. After the prefetch, the
wrapper runs npm with `offline` set and a registry that nothing needs to
answer: `npm ci`, the build scripts and the tests read only what the
lockfiles name.

A command that needs a download the lockfiles do not name stops with
npm's `ENOTCACHED` error, and the wrapper adds a line that names
`npm-purifier lock`. `NPM_PURIFIER=0` turns the wrapper off for one
command. `NPM_PURIFIER_LOCKFILE` names an `npm-purifier.lock.json` other
than the one at the project root, for the wrapper and for every
`npm-purifier` command. `NPM_PURIFIER_TOOL_LOCKFILE` names a
`package-lock.json` kept outside the project, for every `npm-purifier`
command. A flake that keeps the files outside the project can set both
variables in its development shell to the paths it passes the builder.

npm in the project reads the `package-lock.json` of the project. It reads
neither an outside copy nor the `completions` of an outside
`npm-purifier.lock.json`, which serve the Nix build. Where those differ
from the file in the project, the wrapper stops with `ENOTCACHED` on the
entries the prefetch did not keep, and says so. The development loop works
offline with both lockfiles committed in the project, which is the
recommended setup.

## Editor

Editors and language servers read `node_modules`, which `npm ci` through
the wrapper fills as plain npm does, so they need no setup of their own.
An editor that runs npm itself (task runners, script panels) gets the
wrapper when it starts from the `nix develop` shell, or from a direnv
`use flake` of a flake whose development shell includes the wrapper.

## Troubleshooting

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

## Supported language repositories

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

npm-purifier builds for x86_64-linux and aarch64-linux.

`npm-purifier.lock.json` holds only what `package-lock.json` cannot
supply. Per git dependency, keyed by its `resolved`, it holds the Nix hash
of the checkout, which npm does not record. For a hosted repository it
adds the archive URL and the URL to fetch the checkout from, which npm's
rules for the host decide. For a cloned repository it adds whether there
are submodules, the raw commit objects, and the URL and commit of each
submodule, which live in the repository itself. For a prepared dependency
it adds the dependency's own lockfile. The commit and the directory in the
repository come from `resolved`.

A flake can also build a project as an external build, without changing
the project's repository. The flake keeps `npm-purifier.lock.json` outside
the project and passes its path to the builder as `lockFile`. It can keep
its own copy of `package-lock.json` outside the project too, and pass it
as `packageLock`; the build installs from that copy in place of the one
in `src`. A project whose committed `package-lock.json` is missing, stale
or incomplete builds this way from its source as published.

`npm-purifier lock --lockfile <path> --tool-lockfile <path>` writes both
outside files and leaves the files in the project as they are. When the
outside `package-lock.json` does not exist yet, the lock run starts from
the one in the project. `NPM_PURIFIER_TOOL_LOCKFILE` does the same as
`--tool-lockfile`, and `npm-purifier update` takes both options too.

A flake that keeps only `npm-purifier.lock.json` outside, and the
`package-lock.json` of the project as it is, can still build a project
whose `package-lock.json` leaves out the URL or integrity of entries. The
lock run records them in the `completions` of the outside
`npm-purifier.lock.json`, keyed by their place in `package-lock.json`, and
the build installs from a copy of `package-lock.json` completed with
them.

## Examples

### Working on commander.js

[commander.js](https://github.com/tj/commander.js) is a command-line
library with a test suite. In a checkout of it, enter the shell, lock and
work offline as usual:

```zsh
git clone https://github.com/tj/commander.js
cd commander.js
nix develop github:nix-purifiers/npm-purifier
npm-purifier lock
npm ci
npm test
```

commander.js has no git dependencies, so the lock run writes no
`npm-purifier.lock.json`. From the same directory, this builds the package
and runs its tests in the sandbox, with no Nix file added to the checkout:

```zsh
nix build --impure --expr '
  let
    purifier = builtins.getFlake "github:nix-purifiers/npm-purifier";
    pkgs = import purifier.inputs.nixpkgs {
      system = builtins.currentSystem;
      overlays = [ purifier.overlays.default ];
    };
    project = pkgs.npm-purifier.buildNpmProject {
      src = ./.;
      doCheck = true;
    };
  in
  project.packages.commander'
```

### Building http-server without changing it

[http-server](https://github.com/http-party/http-server) is a static file
server. Its `package-lock.json` leaves out the URL and integrity of many
entries, so this example keeps the lockfile of npm-purifier outside the
checkout, and the checkout stays as the authors published it:

```zsh
git clone https://github.com/http-party/http-server
cd http-server
nix develop github:nix-purifiers/npm-purifier
npm-purifier lock --lockfile ../http-server.lock.json
```

The lock run leaves the checkout as it is and records the missing URLs and
integrities in `../http-server.lock.json`. From the checkout, this builds
the server with that lockfile:

```zsh
nix build --impure --expr '
  let
    purifier = builtins.getFlake "github:nix-purifiers/npm-purifier";
    pkgs = import purifier.inputs.nixpkgs {
      system = builtins.currentSystem;
      overlays = [ purifier.overlays.default ];
    };
  in
  (pkgs.npm-purifier.buildNpmProject {
    src = ./.;
    lockFile = ../http-server.lock.json;
  }).packages.http-server'
```

A flake of your own can do the same with http-server as an input that has
`flake = false`, passing the path of its own `npm-purifier.lock.json` as
`lockFile`.

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
