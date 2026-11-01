# SPDX-License-Identifier: MIT
#
# Reads a package-lock.json (lockfileVersion 2 or 3) and, when the project
# has git dependencies, the npm-purifier.lock.json that `npm nix-lock`
# writes beside it, at evaluation time. It returns
#
#   downloads   one entry per tarball the install needs, as
#               { path, url, hash }: `path` is where the tarball's content
#               lies in npm's cache (_cacache/<path>), `url` is the lock's
#               `resolved` and `hash` the lock's SRI `integrity`. An entry
#               also carries the lock's `os`, `cpu` and `libc` lists where
#               the lock has them. The tarballs that prepared git
#               dependencies install are among them.
#   git         the git dependencies, by their `resolved`, as the entries
#               of npm-purifier.lock.json (see pkgs/npm/nix-lock.js)
#   packages    the project's own packages (the root, its workspaces and
#               the local directories it depends on), by package name, as
#               { name, version, dir, bin }; a root that declares
#               workspaces is one only when it has commands. `dir` is the
#               package's directory relative to the project root ("" for
#               the root) and `bin` its commands, as command name to file
#
# npm looks a registry tarball up in its cache by integrity, so a cache
# holding only the content files, at the paths cacache derives from each
# integrity, serves `npm ci --offline` without index entries.
{
  lib,
  lockFile,
  # The lockfile of the git dependencies. It is read only when it exists.
  purifierLockFile ? dirOf lockFile + "/npm-purifier.lock.json",
  # The platform the install runs for, as a nixpkgs platform. Packages for
  # other operating systems or CPUs (such as the per-platform binaries of
  # esbuild) are left out of `downloads`, as npm leaves them out of the
  # install.
  platform,
}:
let
  lock = lib.importJSON lockFile;

  packagesOf =
    name: l:
    let
      version = l.lockfileVersion or 1;
    in
    if version >= 2 then
      l.packages
    else
      throw "npm-purifier: ${name} is lockfileVersion ${toString version}; run `npm install` with npm 7 or newer to write lockfileVersion 3.";

  packages = packagesOf (toString lockFile) lock;

  # A key under node_modules/ is an installed package; any other key is a
  # package of the project itself ("" for the root, a directory for a
  # workspace or a local dependency).
  isInstalled = key: lib.hasPrefix "node_modules/" key || lib.hasInfix "/node_modules/" key;

  isGit = resolved: lib.hasPrefix "git+" resolved;

  nodeOs =
    if platform.isLinux then
      "linux"
    else if platform.isDarwin then
      "darwin"
    else
      platform.parsed.kernel.name;
  nodeCpu =
    {
      x86_64 = "x64";
      aarch64 = "arm64";
      i686 = "ia32";
      armv7l = "arm";
    }
    .${platform.parsed.cpu.name} or platform.parsed.cpu.name;
  nodeLibc = if platform.isMusl then "musl" else "glibc";

  # npm's rule for the os, cpu and libc fields: a name that is listed
  # allows, a name listed with a leading "!" forbids, and a list of only
  # forbidden names allows the rest.
  allows =
    value: list:
    let
      denied = lib.elem "!${value}" list;
      allowed = lib.filter (x: !lib.hasPrefix "!" x) list;
    in
    !denied && (allowed == [ ] || lib.elem value allowed);
  forPlatform =
    entry:
    allows nodeOs (entry.os or [ ])
    && allows nodeCpu (entry.cpu or [ ])
    && (platform.isLinux -> allows nodeLibc (entry.libc or [ ]));

  remote =
    name: key: entry:
    let
      resolved = entry.resolved;
      isHttp = lib.hasPrefix "https://" resolved || lib.hasPrefix "http://" resolved;
    in
    if !isHttp then
      throw "npm-purifier: ${key} in ${name} comes from ${resolved}, which is neither a tarball URL, a git repository nor a path."
    else if !(entry ? integrity) then
      throw "npm-purifier: ${key} (${resolved}) has no integrity in ${name}; run `npm install` to record one."
    else
      let
        # An integrity may list several hashes; the strongest comes first
        # in what npm writes.
        sri = builtins.head (lib.splitString " " entry.integrity);
        algorithm = builtins.head (lib.splitString "-" sri);
        hex = builtins.convertHash {
          hash = sri;
          toHashFormat = "base16";
        };
      in
      {
        path = "content-v2/${algorithm}/${builtins.substring 0 2 hex}/${builtins.substring 2 2 hex}/${builtins.substring 4 (-1) hex}";
        url = resolved;
        # npm knows one URL per tarball.
        mirrors = [ ];
        hash = sri;
      }
      // lib.getAttrs (builtins.filter (f: entry ? ${f}) [
        "os"
        "cpu"
        "libc"
      ]) entry;

  # Installed packages that come from elsewhere: not links to the
  # project's own directories, not bundled inside another tarball, and not
  # tarballs inside the project (`file:` specs, which npm reads from the
  # source).
  installed =
    ps:
    lib.filterAttrs (
      key: entry:
      isInstalled key
      && !(entry.link or false)
      && !(entry.inBundle or false)
      && entry ? resolved
      && !lib.hasPrefix "file:" entry.resolved
    ) ps;

  tarballsOf =
    name: ps:
    lib.mapAttrsToList (key: entry: remote name key entry) (
      lib.filterAttrs (_: entry: !isGit entry.resolved) (installed ps)
    );
  gitOf =
    ps:
    lib.mapAttrsToList (_: entry: entry.resolved) (
      lib.filterAttrs (_: entry: isGit entry.resolved) (installed ps)
    );

  purifierLockName = toString purifierLockFile;
  hasPurifierLock = builtins.pathExists purifierLockFile;
  purifierLock = lib.importJSON purifierLockFile;
  needsPurifierLock = gitOf packages != [ ];

  git =
    if !needsPurifierLock then
      { }
    else if !hasPurifierLock then
      throw "npm-purifier: ${toString lockFile} has git dependencies, and ${purifierLockName} does not exist; run `npm nix-lock`."
    else if purifierLock.packageLockSha256 != builtins.hashFile "sha256" lockFile then
      throw "npm-purifier: ${purifierLockName} was made for another package-lock.json; run `npm nix-lock`."
    else
      purifierLock.git;

  # Every git dependency the install meets, including those of prepared
  # git dependencies, needs its entry.
  gitEntry =
    resolved:
    git.${resolved}
      or (throw "npm-purifier: ${purifierLockName} has no entry for ${resolved}; run `npm nix-lock`.");
  preparationLocks = lib.mapAttrsToList (
    resolved: entry: lib.nameValuePair resolved entry.packageLock
  ) (lib.filterAttrs (_: entry: entry ? packageLock) git);

  allTarballs =
    tarballsOf (toString lockFile) packages
    ++ lib.concatMap (
      p: tarballsOf "the lockfile of ${p.name}" (packagesOf "the lockfile of ${p.name}" p.value)
    ) preparationLocks;
  allGit =
    gitOf packages
    ++ lib.concatMap (p: gitOf (packagesOf "the lockfile of ${p.name}" p.value)) preparationLocks;

  # The same tarball can be installed at several places in the tree; the
  # cache holds it once. Tarballs for other platforms stay out.
  downloads = builtins.filter forPlatform (
    builtins.attrValues (lib.listToAttrs (map (d: lib.nameValuePair d.path d) allTarballs))
  );

  binOf =
    entry:
    let
      bin = entry.bin or { };
    in
    if builtins.isString bin then { ${lib.last (lib.splitString "/" entry.name)} = bin; } else bin;

  # The project's own packages: the root, the workspaces and the local
  # directories the project depends on. A root that declares workspaces
  # and has no commands only coordinates the workspaces, and stays out.
  own = lib.filterAttrs (
    key: entry:
    !isInstalled key
    && !lib.hasPrefix "/" key
    && entry ? name
    && !(key == "" && entry ? workspaces && binOf entry == { })
  ) packages;
in
{
  inherit downloads;
  git = lib.genAttrs (lib.unique allGit) gitEntry;
  packages = lib.listToAttrs (
    lib.mapAttrsToList (
      key: entry:
      lib.nameValuePair entry.name {
        inherit (entry) name;
        version = entry.version or "0.0.0";
        dir = key;
        bin = binOf entry;
      }
    ) own
  );
}
