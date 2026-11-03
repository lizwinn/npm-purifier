// SPDX-License-Identifier: MIT
// Publish the exact exported repository bytes using npm's auth and options.
const fs = require('node:fs')
const path = require('node:path')
const { execFileSync } = require('node:child_process')
const [npm, repository, catalog, ...args] = process.argv.slice(2)
const modules = JSON.parse(fs.readFileSync(catalog, 'utf8')).modules
const options = args.some(arg => arg === '--tag' || arg.startsWith('--tag=')) ? args : ['--tag', 'nix', ...args]
for (const item of modules.sort((a, b) => Number(a.primary) - Number(b.primary) || a.name.localeCompare(b.name))) {
  execFileSync(npm, ['publish', path.join(repository, item.archive), ...options], { stdio: 'inherit' })
}
