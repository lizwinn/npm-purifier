// SPDX-License-Identifier: MIT
//
// The lock run of npm-purifier (`npm nix-lock`). package-lock.json names
// every registry tarball with its integrity, so Nix fetches those from it
// alone. Some lockfiles leave the URL or the integrity of an entry out,
// and npm fetches the registry's metadata for it at install time; the run
// records both in package-lock.json, as a later `npm install` would. A git
// dependency is the exception: npm skips its integrity and
// fetches it again from the repository, so this run records what a Nix
// build needs to serve it offline, in npm-purifier.lock.json beside
// package-lock.json:
//
//   - the commit, as a Nix hash of its checkout;
//   - for a repository on a known host, the archive URL npm downloads
//     instead of cloning;
//   - for any other repository, the URL npm clones, the raw commit object,
//     and the URL, commit and commit object of each submodule, from which
//     a build makes the repositories again;
//   - for a dependency that npm prepares (one with a prepare, build or
//     install script, or with workspaces), the lockfile of its own
//     dependencies, which npm installs before running the script. The run
//     takes the lockfile from the repository, or makes one with
//     `npm install --package-lock-only` when the repository has none.
//
// The dependencies of a prepared git dependency can be git dependencies
// themselves; the run records those too.
//
// Usage: node nix-lock.js <project root>
// The environment names npm's own modules (NPM_PURIFIER_NPM_MODULES) and
// npm (NPM_PURIFIER_NPM).

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

const modules = process.env.NPM_PURIFIER_NPM_MODULES;
const npa = require(path.join(modules, "npm-package-arg"));
const npm = process.env.NPM_PURIFIER_NPM;

// The scripts that make npm prepare a git dependency before packing it
// (pacote's GitFetcher).
const prepareScripts = ["postinstall", "build", "preinstall", "install", "prepack", "prepare"];

// Whether npm prepares a git dependency with this package.json.
const needsPreparation = (manifest) =>
  Boolean(manifest.workspaces) || prepareScripts.some((s) => (manifest.scripts || {})[s]);

const readJson = (file) => JSON.parse(fs.readFileSync(file, "utf8"));

// The installed registry packages of a lockfile that lack a `resolved` URL
// or an `integrity`, by their key. npm fetches the registry's metadata to
// fill such an entry in at install time, which an offline install cannot.
const incompleteEntries = (lock) =>
  Object.entries(lock.packages || {})
    .filter(([key, entry]) => {
      if (key === "" || !key.includes("node_modules/")) return false;
      if (entry.link || entry.inBundle) return false;
      if (entry.resolved && !/^https?:\/\//.test(entry.resolved)) return false;
      return !entry.resolved || !entry.integrity;
    })
    .map(([key]) => key);

// The name of the package installed at a lockfile key.
const nameOf = (key, entry) => entry.name || key.slice(key.lastIndexOf("node_modules/") + "node_modules/".length);

// Fills in the `resolved` and `integrity` of each incomplete entry, from
// `dist`, which gives the registry's { tarball, integrity } for a name and
// a version. The fields go where npm writes them, after `version`.
const completeLock = (lock, dist) => {
  const keys = incompleteEntries(lock);
  for (const key of keys) {
    const entry = lock.packages[key];
    const found = dist(nameOf(key, entry), entry.version);
    const { version, resolved, integrity, ...rest } = entry;
    lock.packages[key] = {
      version,
      resolved: resolved || found.tarball,
      integrity: integrity || found.integrity,
      ...rest,
    };
  }
  return keys;
};

const registryDist = (name, version) =>
  JSON.parse(
    execFileSync(npm, ["view", `${name}@${version}`, "dist", "--json"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "inherit"],
    }),
  );

// The git dependencies of a lockfile, by their `resolved`.
const gitDependencies = (lock) => {
  const found = [];
  for (const [key, entry] of Object.entries(lock.packages || {})) {
    if (key === "" || entry.link || !entry.resolved) continue;
    let spec;
    try {
      spec = npa(entry.resolved);
    } catch {
      continue;
    }
    if (spec.type === "git") found.push(entry.resolved);
  }
  return found;
};

const prefetch = (url, rev, { submodules, leaveDotGit }) => {
  const args = ["--url", url, "--rev", rev, "--quiet"];
  if (submodules) args.push("--fetch-submodules");
  if (leaveDotGit) args.push("--leave-dotGit");
  return JSON.parse(execFileSync("nix-prefetch-git", args, { encoding: "utf8" }));
};

// Resolves a submodule URL that is relative to its superproject's URL, as
// git does.
const resolveSubmoduleUrl = (parent, url) => {
  if (!url.startsWith("./") && !url.startsWith("../")) return url;
  let base = parent.replace(/\/+$/, "").replace(/\.git$/, "");
  let rest = url;
  while (rest.startsWith("../") || rest.startsWith("./")) {
    if (rest.startsWith("../")) {
      base = base.slice(0, base.lastIndexOf("/"));
      rest = rest.slice(3);
    } else {
      rest = rest.slice(2);
    }
  }
  return `${base}/${rest}`;
};

// The submodules of a checkout, recursively, as the URL git fetches and
// the directory of the submodule inside the checkout.
const submodulesOf = (checkout, url, prefix = "") => {
  const file = path.join(checkout, prefix, ".gitmodules");
  if (!fs.existsSync(file)) return [];
  const text = fs.readFileSync(file, "utf8");
  const found = [];
  let current = null;
  for (const line of text.split("\n")) {
    const section = line.match(/^\s*\[submodule\s+"(.*)"\]\s*$/);
    if (section) {
      current = {};
      found.push(current);
      continue;
    }
    const setting = line.match(/^\s*(path|url)\s*=\s*(.*?)\s*$/);
    if (setting && current) current[setting[1]] = setting[2];
  }
  return found.flatMap((s) => {
    const dir = path.posix.join(prefix, s.path);
    const subUrl = resolveSubmoduleUrl(url, s.url);
    return [{ url: subUrl, path: dir }, ...submodulesOf(checkout, subUrl, dir)];
  });
};

// The commit `rev` of the repository at `url`, as { object, gitlinks }:
// `object` is the raw commit object, base64, and `gitlinks` lists the
// submodule entries of its tree as { path, rev }.
const commitOf = (url, rev) => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "npm-purifier-commit-"));
  try {
    const git = (...args) => execFileSync("git", ["-C", tmp, ...args]);
    git("init", "-q");
    git("fetch", "-q", "--depth=1", url, rev);
    const object = git("cat-file", "commit", rev).toString("base64");
    const gitlinks = git("ls-tree", "-r", rev)
      .toString("utf8")
      .split("\n")
      .filter((line) => line.startsWith("160000 commit "))
      .map((line) => {
        const [meta, file] = line.split("\t");
        return { path: file, rev: meta.split(" ")[2] };
      });
    return { object, gitlinks };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
};

// The submodules of the repository at `url`, recursively, with what a
// build needs to make each of them again: its URL, its directory in the
// checkout of the top repository, its commit, and that commit as commitOf
// gives it. `urls` lists every submodule of the checkout as submodulesOf
// finds them.
const repositoryOf = (url, rev, gitlinks, urls, prefix) =>
  gitlinks.flatMap((link) => {
    const dir = path.posix.join(prefix, link.path);
    const found = urls.find((s) => s.path === dir);
    if (!found) throw new Error(`${url} at ${rev} has a submodule at ${dir} without a URL in .gitmodules`);
    const commitObject = commitOf(found.url, link.rev);
    return [
      { url: found.url, path: dir, rev: link.rev, commitObject },
      ...repositoryOf(found.url, link.rev, commitObject.gitlinks, urls, dir),
    ];
  });

// The lockfile npm installs before preparing the dependency at `dir`, or
// null when npm does not prepare it.
const preparationLock = (dir) => {
  if (!needsPreparation(readJson(path.join(dir, "package.json")))) return null;
  for (const name of ["npm-shrinkwrap.json", "package-lock.json"]) {
    const file = path.join(dir, name);
    if (fs.existsSync(file)) return { lock: readJson(file), inject: false };
  }
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "npm-purifier-lock-"));
  try {
    fs.cpSync(dir, tmp, { recursive: true, filter: (src) => path.basename(src) !== ".git" });
    fs.chmodSync(tmp, 0o755);
    execFileSync(
      npm,
      ["install", "--package-lock-only", "--ignore-scripts", "--no-audit", "--no-fund"],
      { cwd: tmp, stdio: ["ignore", "ignore", "inherit"] }
    );
    return { lock: readJson(path.join(tmp, "package-lock.json")), inject: true };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
};

// Where npm gets the git dependency `resolved` from, as npm itself works
// it out (npm-package-arg and hosted-git-info): { rev, subdir, url } with
// `archive`, the archive URL npm downloads, for a repository on a known
// host, and with `repository`, the URL npm clones, for any other.
const sourceOf = (resolved) => {
  const spec = npa(resolved);
  const rev = spec.gitCommittish;
  if (!/^[0-9a-f]{40}$/.test(rev || "")) {
    throw new Error(`${resolved} does not name a commit; run \`npm install\` to lock it`);
  }
  const subdir = spec.gitSubdir ? spec.gitSubdir.replace(/^\/+/, "") : "";
  const hosted = spec.hosted;
  if (hosted && hosted.tarball) {
    return {
      rev,
      subdir,
      url: hosted.https({ noCommittish: true }).replace(/^git\+/, ""),
      archive: hosted.tarball({ noCommittish: false }),
    };
  }
  return { rev, subdir, url: spec.fetchSpec, repository: spec.fetchSpec };
};

const lockGit = (resolved) => {
  const source = sourceOf(resolved);
  const { rev, subdir } = source;
  const entry = {};
  let fetched;
  if (source.archive) {
    // npm downloads the host's archive of the commit, which holds no
    // submodules.
    const { url } = source;
    fetched = prefetch(url, rev, { submodules: false, leaveDotGit: false });
    entry.git = { url, rev, submodules: false, leaveDotGit: false, commitObject: null };
    entry.archive = source.archive;
  } else {
    // npm clones the repository and its submodules with git. A checkout
    // that keeps its .git directory has no stable hash, because git packs
    // objects differently from run to run, so the run locks a plain
    // checkout, and the raw commit objects from which a build makes the
    // repositories again.
    const { url } = source;
    const probe = prefetch(url, rev, { submodules: false, leaveDotGit: false });
    const submodules = fs.existsSync(path.join(probe.path, ".gitmodules"));
    fetched = submodules ? prefetch(url, rev, { submodules, leaveDotGit: false }) : probe;
    // `leaveDotGit` asks the build for a .git directory, which it makes
    // from the checkout and `commitObject`. `hash` is the NAR hash of the
    // plain checkout.
    const commitObject = commitOf(url, rev);
    entry.git = { url, rev, submodules, leaveDotGit: true, commitObject };
    entry.repository = url;
    const urls = submodulesOf(fetched.path, url);
    entry.submodules = repositoryOf(url, rev, commitObject.gitlinks, urls, "");
  }
  entry.hash = fetched.hash;
  if (subdir) entry.subdir = subdir;
  const preparation = preparationLock(path.join(fetched.path, subdir));
  if (preparation) {
    entry.packageLock = preparation.lock;
    entry.injectPackageLock = preparation.inject;
  }
  return entry;
};

const main = (root) => {
  const packageLockPath = path.join(root, "package-lock.json");
  const purifierLockPath = path.join(root, "npm-purifier.lock.json");
  const packageLock = readJson(packageLockPath);
  const completed = completeLock(packageLock, registryDist);
  if (completed.length > 0) {
    fs.writeFileSync(packageLockPath, JSON.stringify(packageLock, null, 2) + "\n");
    const shown = completed.slice(0, 3).join(", ");
    const more = completed.length > 3 ? ` and ${completed.length - 3} more` : "";
    process.stderr.write(
      `npm-purifier: recorded the tarball URL and integrity of ${shown}${more} in package-lock.json\n`,
    );
  }
  const packageLockText = fs.readFileSync(packageLockPath);
  // A git dependency names its commit, so an entry made for the same
  // `resolved` still holds; the run reuses it rather than fetching again.
  const previous = fs.existsSync(purifierLockPath) ? readJson(purifierLockPath).git || {} : {};
  const queue = gitDependencies(JSON.parse(packageLockText));
  const git = {};
  while (queue.length > 0) {
    const resolved = queue.shift();
    if (git[resolved]) continue;
    if (previous[resolved]) {
      git[resolved] = previous[resolved];
    } else {
      process.stderr.write(`npm-purifier: locking ${resolved}\n`);
      git[resolved] = lockGit(resolved);
    }
    if (git[resolved].packageLock) queue.push(...gitDependencies(git[resolved].packageLock));
  }
  if (Object.keys(git).length === 0) {
    fs.rmSync(purifierLockPath, { force: true });
    process.stderr.write("npm-purifier: package-lock.json has no git dependencies\n");
    return;
  }
  const sorted = Object.fromEntries(Object.keys(git).sort().map((k) => [k, git[k]]));
  const lock = {
    version: 1,
    packageLockSha256: crypto.createHash("sha256").update(packageLockText).digest("hex"),
    git: sorted,
  };
  fs.writeFileSync(purifierLockPath, JSON.stringify(lock, null, 2) + "\n");
  process.stderr.write(`npm-purifier: wrote ${purifierLockPath}\n`);
};

// The parts that need no network, for pkgs/npm/nix-lock.test.js.
module.exports = {
  gitDependencies,
  sourceOf,
  resolveSubmoduleUrl,
  submodulesOf,
  needsPreparation,
  incompleteEntries,
  completeLock,
};

if (require.main === module) {
  main(path.resolve(process.argv[2] || "."));
}
