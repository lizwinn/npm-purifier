// SPDX-License-Identifier: MIT
// Capture npm's actual runtime graph and prepared package contents.
'use strict';
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const modules = process.env.NPM_PURIFIER_NPM_MODULES;
const Arborist = require(path.join(modules, '@npmcli/arborist'));
const tar = require(path.join(modules, 'tar'));
const semver = require(path.join(modules, 'semver'));
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const tarballName = name => name.replaceAll('@', '').replaceAll('/', '__') + '.tgz';

async function capture(root, release, destination, ownPackages) {
  root = fs.realpathSync(root);
  const tree = await new Arborist({path: root}).loadActual();
  const candidates = new Map();
  for (const item of tree.inventory.values()) {
    const node = item.target;
    candidates.set(fs.realpathSync(node.path), node);
  }
  candidates.set(fs.realpathSync(tree.path), tree);
  const owned = new Map();
  for (const pkg of ownPackages) {
    const directory = fs.realpathSync(path.resolve(root, pkg.dir || '.'));
    const node = candidates.get(directory);
    if (!node) throw new Error(`npm has no captured local package at ${directory}`);
    owned.set(node, pkg);
  }
  const nodes = new Map();
  const keyOf = node => path.relative(root, node.target.path).replaceAll(path.sep, '/') || '.';
  function visit(node) {
    node = node.target;
    const key = keyOf(node);
    if (nodes.has(key)) return;
    const dependencies = {};
    nodes.set(key, {node, dependencies});
    for (const [name, edge] of [...node.edgesOut].sort(([a], [b]) => a.localeCompare(b))) {
      if (edge.dev || !edge.to) continue;
      const target = edge.to.target;
      dependencies[name] = {type: edge.type, target: keyOf(target)};
      visit(target);
    }
  }
  for (const node of owned.keys()) visit(node);
  fs.mkdirSync(destination, {recursive: true});
  const archives = path.join(destination, 'archives');
  fs.mkdirSync(archives, {recursive: true});
  fs.mkdirSync(path.join(destination, 'contents'), {recursive: true});
  const output = {version: 1, os: process.platform, cpu: process.arch,
    nodeMajor: Number(process.versions.node.split('.')[0]), primaries: {}, nodes: {}};
  for (const [node, pkg] of owned) output.primaries[pkg.name] = keyOf(node);
  for (const [key, {node, dependencies}] of nodes) {
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'npm-artifact-'));
    try {
      const directory = path.join(temporary, 'package');
      const own = owned.get(node);
      if (own) {
        await tar.x({file: path.join(release, tarballName(own.name)), cwd: temporary, strict: true});
        fs.rmSync(path.join(directory, 'node_modules'), {recursive: true, force: true});
      } else {
        fs.cpSync(node.path, directory, {recursive: true, dereference: false,
          filter: source => {
            const relative = path.relative(node.path, source);
            const first = relative.split(path.sep)[0];
            return first !== 'node_modules' && first !== '.git';
          }});
      }
      const metadata = read(path.join(directory, 'package.json'));
      metadata.name = metadata.name || node.name;
      metadata.version = semver.valid(metadata.version) || '0.0.0';
      if (!metadata.name) throw new Error(`npm artifact lacks a native name: ${key}`);
      const contentHash = execFileSync(process.env.NPM_PROJECTION_NIX,
        ['--offline', '--extra-experimental-features', 'nix-command', 'hash', 'path', '--type', 'sha256', directory],
        {encoding: 'utf8'}).trim();
      let native = false;
      function inspect(folder) {
        for (const entry of fs.readdirSync(folder, {withFileTypes: true})) {
          const file = path.join(folder, entry.name);
          if (entry.isDirectory()) inspect(file);
          else if (entry.isFile()) {
            if (entry.name.endsWith('.node')) native = 'node-addon';
            else if (!native) {
              const descriptor = fs.openSync(file, 'r');
              try {
                const header = Buffer.alloc(4);
                if (fs.readSync(descriptor, header, 0, 4, 0) === 4 && header.equals(Buffer.from([127, 69, 76, 70]))) native = 'executable';
              } finally { fs.closeSync(descriptor); }
            }
          }
        }
      }
      inspect(directory);
      const filename = hash(key) + '.tgz';
      await tar.c({file: path.join(archives, filename), cwd: temporary, portable: true,
        gzip: {mtime: 0}, mtime: new Date(0), noMtime: true}, ['package']);
      // Keep uncompressed contents so Nix discovers runtime references
      // hidden inside the compressed publication artifacts.
      fs.cpSync(directory, path.join(destination, 'contents', hash(key)), {recursive: true});
      output.nodes[key] = {name: metadata.name, version: metadata.version,
        package: metadata, archive: filename, contentHash, dependencies, native};
    } finally { fs.rmSync(temporary, {recursive: true, force: true}); }
  }
  fs.writeFileSync(path.join(destination, 'graph.json'), JSON.stringify(output));
}

if (require.main === module) {
  const [root, release, destination, own] = process.argv.slice(2);
  capture(root, release, destination, read(own)).catch(error => {console.error(error); process.exitCode = 1;});
}
module.exports = {capture};
