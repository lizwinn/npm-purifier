// SPDX-License-Identifier: MIT
// Publish the exact exported repository bytes using npm's auth and options.
const fs = require('node:fs')
const path = require('node:path')
const { execFileSync, spawnSync } = require('node:child_process')
const [npm, repository, catalog, ...args] = process.argv.slice(2)
const modules = JSON.parse(fs.readFileSync(catalog, 'utf8')).modules
const options = args.some(arg => arg === '--tag' || arg.startsWith('--tag=')) ? args : ['--tag', 'nix', ...args]
const registryOptions = []
for (let index=0; index<args.length; index++) {
  if (['--registry','--userconfig'].includes(args[index])) registryOptions.push(args[index],args[++index])
  else if (/^--(registry|userconfig)=/.test(args[index])) registryOptions.push(args[index])
}
for (const item of modules.sort((a, b) => Number(a.primary) - Number(b.primary) || a.name.localeCompare(b.name))) {
  if (!item.primary) {
    const flags = [...registryOptions]
    if (!flags.some(arg=>arg === '--registry' || arg.startsWith('--registry=')) && item.package.publishConfig?.registry) flags.push('--registry',item.package.publishConfig.registry)
    const existing = spawnSync(npm,['view',`${item.name}@${item.version}`,'dist.integrity','--json',...flags],{encoding:'utf8'})
    if (existing.status === 0) {
      const integrity = JSON.parse(existing.stdout || 'null')
      if (integrity === item.integrity) continue
      if (integrity != null) throw new Error(`Registry artifact differs from Nix input: ${item.name}@${item.version}`)
    }
  }
  execFileSync(npm, ['publish' , path.join(repository, item.archive), ...options], { stdio: 'inherit' })
}
