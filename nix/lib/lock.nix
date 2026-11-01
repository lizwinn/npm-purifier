# SPDX-License-Identifier: MIT
#
# Reads a package-lock.json (lockfileVersion 2 or 3) at evaluation time.
# It returns
#
#   downloads   one entry per registry tarball the install needs, as
#               { path, url, hash }: `path` is where the tarball's content
#               lies in npm's cache (_cacache/<path>), `url` is the lock's
#               `resolved` and `hash` the lock's SRI `integrity`
#   packages    the project's own packages (the root and its workspaces), by
#               package name, as { name, version, dir, bin }; a root that
#               declares workspaces is one only when it has commands. `dir` is the
#               package's directory relative to the project root ("" for
#               the root) and `bin` its commands, as command name to file
#
# npm looks a tarball up in its cache by integrity, so a cache holding only
# the content files, at the paths cacache derives from each integrity,
# serves `npm ci --offline` without index entries.
{
  lib,
  lockFile,
  # The platform the install runs for, as a nixpkgs platform. Optional
  # packages for other operating systems or CPUs (such as the
  # per-platform binaries of esbuild) are left out of `downloads`, as npm
  # leaves them out of the install.
  platform,
}:
let
  lock = lib.importJSON lockFile;
  version = lock.lockfileVersion or 1;

  packages =
    if version >= 2 then
      lock.packages
    else
      throw "npm-purifier: ${toString lockFile} is lockfileVersion ${toString version}; run `npm install` with npm 7 or newer to write lockfileVersion 3.";

  # A key under node_modules/ is an installed package; any other key is a
  # package of the project itself ("" for the root, a directory for a
  # workspace).
  isInstalled = key: lib.hasPrefix "node_modules/" key || lib.hasInfix "/node_modules/" key;

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
    key: entry:
    let
      resolved = entry.resolved;
      isHttp = lib.hasPrefix "https://" resolved || lib.hasPrefix "http://" resolved;
    in
    if !isHttp then
      throw "npm-purifier: ${key} comes from ${resolved}, and npm-purifier fetches only registry and http(s) tarballs."
    else if !(entry ? integrity) then
      throw "npm-purifier: ${key} (${resolved}) has no integrity in ${toString lockFile}; run `npm install` to record one."
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
        hash = sri;
      };

  # Installed packages that come from elsewhere: not links to the
  # project's own directories, not bundled inside another tarball, and not
  # tarballs inside the project (`file:` specs, which npm reads from the
  # source).
  fetched = lib.filterAttrs (
    key: entry:
    isInstalled key
    && !(entry.link or false)
    && !(entry.inBundle or false)
    && entry ? resolved
    && !lib.hasPrefix "file:" entry.resolved
    && (entry.optional or false -> forPlatform entry)
  ) packages;

  # The same tarball can be installed at several places in the tree; the
  # cache holds it once.
  downloads = builtins.attrValues (
    lib.listToAttrs (
      lib.mapAttrsToList (
        key: entry:
        let
          d = remote key entry;
        in
        lib.nameValuePair d.path d
      ) fetched
    )
  );

  binOf =
    entry:
    let
      bin = entry.bin or { };
    in
    if builtins.isString bin then { ${lib.last (lib.splitString "/" entry.name)} = bin; } else bin;

  # The project's own packages: the root and the workspaces, which lie
  # inside the project. A `file:` dependency outside the project root has a
  # key starting with "../" and stays out. A root that declares workspaces
  # and has no commands only coordinates the workspaces, and stays out too.
  own = lib.filterAttrs (
    key: entry:
    !isInstalled key
    && !lib.hasPrefix "../" key
    && !lib.hasPrefix "/" key
    && entry ? name
    && !(key == "" && entry ? workspaces && binOf entry == { })
  ) packages;
in
{
  inherit downloads;
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
