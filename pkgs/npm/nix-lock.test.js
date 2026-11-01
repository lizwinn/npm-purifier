// SPDX-License-Identifier: MIT
//
// Unit tests of the lock run's parsing: which lockfile entries are git
// dependencies, where npm gets each one from, how submodule URLs resolve,
// and which dependencies npm prepares. They need no network; the flake's
// check `lock-run-units` runs them with `node --test`.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const {
  gitDependencies,
  sourceOf,
  resolveSubmoduleUrl,
  submodulesOf,
  needsPreparation,
} = require("./nix-lock.js");

const sha = "98e8ff1da1a89f93d1397a24d7413ed15421c139";

test("gitDependencies takes the git entries and nothing else", () => {
  const lock = {
    packages: {
      "": { name: "root", dependencies: { a: "1" } },
      "node_modules/a": { resolved: "https://registry.npmjs.org/a/-/a-1.0.0.tgz", integrity: "sha512-x" },
      "node_modules/b": { resolved: `git+ssh://git@github.com/o/b.git#${sha}` },
      "node_modules/c": { resolved: "packages/c", link: true },
      "node_modules/d": { resolved: "file:vendor/d.tgz" },
      "node_modules/e/node_modules/f": { resolved: `git+https://codeberg.org/o/f.git#${sha}` },
      "packages/c": { name: "c" },
    },
  };
  assert.deepEqual(gitDependencies(lock), [
    `git+ssh://git@github.com/o/b.git#${sha}`,
    `git+https://codeberg.org/o/f.git#${sha}`,
  ]);
});

test("a GitHub dependency comes from the archive of its commit", () => {
  assert.deepEqual(sourceOf(`git+ssh://git@github.com/jonschlinkert/is-number.git#${sha}`), {
    rev: sha,
    subdir: "",
    url: "https://github.com/jonschlinkert/is-number.git",
    archive: `https://codeload.github.com/jonschlinkert/is-number/tar.gz/${sha}`,
  });
});

test("a dependency in a directory of a repository keeps the directory", () => {
  const source = sourceOf(`git+ssh://git@github.com/o/r.git#${sha}::path:packages/x`);
  assert.equal(source.subdir, "packages/x");
  // npm requests the archive with the directory in its URL, so the cache
  // answers that URL.
  assert.equal(source.archive, `https://codeload.github.com/o/r/tar.gz/${sha}%3A%3Apath%3Apackages%2Fx`);
});

test("a GitLab dependency comes from GitLab's archive", () => {
  const source = sourceOf(`git+https://gitlab.com/o/r.git#${sha}`);
  assert.equal(source.archive, `https://gitlab.com/api/v4/projects/o%2Fr/repository/archive.tar.gz?sha=${sha}`);
});

test("a dependency on another host is cloned from its URL", () => {
  assert.deepEqual(sourceOf(`git+https://codeberg.org/o/r.git#${sha}`), {
    rev: sha,
    subdir: "",
    url: "https://codeberg.org/o/r.git",
    repository: "https://codeberg.org/o/r.git",
  });
});

test("a git dependency without a commit asks for npm install", () => {
  assert.throws(() => sourceOf("git+https://codeberg.org/o/r.git#main"), /run `npm install`/);
});

test("submodule URLs resolve against the superproject's URL", () => {
  assert.equal(resolveSubmoduleUrl("https://h/o/r.git", "../s.git"), "https://h/o/s.git");
  assert.equal(resolveSubmoduleUrl("https://h/o/r", "./s.git"), "https://h/o/r/s.git");
  assert.equal(resolveSubmoduleUrl("https://h/o/r.git", "../../p/s.git"), "https://h/p/s.git");
  assert.equal(resolveSubmoduleUrl("https://h/o/r.git", "https://x/s.git"), "https://x/s.git");
});

test("submodulesOf finds nested submodules with their directories", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nix-lock-test-"));
  try {
    fs.writeFileSync(
      path.join(dir, ".gitmodules"),
      '[submodule "vendor/a"]\n\tpath = vendor/a\n\turl = ../a.git\n',
    );
    fs.mkdirSync(path.join(dir, "vendor/a"), { recursive: true });
    fs.writeFileSync(
      path.join(dir, "vendor/a/.gitmodules"),
      '[submodule "deep"]\n\tpath = deep\n\turl = https://x/deep.git\n',
    );
    assert.deepEqual(submodulesOf(dir, "https://h/o/r.git"), [
      { url: "https://h/o/a.git", path: "vendor/a" },
      { url: "https://x/deep.git", path: "vendor/a/deep" },
    ]);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("npm prepares a dependency with a preparing script or workspaces", () => {
  assert.equal(needsPreparation({ name: "a" }), false);
  assert.equal(needsPreparation({ scripts: { test: "x" } }), false);
  assert.equal(needsPreparation({ scripts: { prepare: "x" } }), true);
  assert.equal(needsPreparation({ scripts: { install: "x" } }), true);
  assert.equal(needsPreparation({ workspaces: ["p/*"] }), true);
});
