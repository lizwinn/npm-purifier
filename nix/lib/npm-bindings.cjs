// SPDX-License-Identifier: MIT
// Bind only Nix-supplied coordinates; leave npm's resolver unchanged elsewhere.
const fs = require('node:fs')
const path = require('node:path')
const { pathToFileURL } = require('node:url')
function activate (configuration, modules) {
  const key = Symbol.for('nix-purifiers.npm.bindings')
  const identity = JSON.stringify(configuration) + fs.realpathSync(modules)
  if (globalThis[key]) {
    if (globalThis[key] !== identity) throw new Error('conflicting npm input contexts')
    return
  }
  globalThis[key] = identity
  const load = name => require(require.resolve(name, { paths: [modules] }))
  const byName = new Map()
  const archives = new Map()
  for (const view of configuration) {
    const catalog = JSON.parse(fs.readFileSync(view.catalog, 'utf8'))
    if (catalog.version !== 1) throw new Error('unsupported npm projection catalog')
    for (const item of catalog.modules) {
      const archive = path.resolve(view.repository, item.archive)
      if (!archive.startsWith(path.resolve(view.repository) + path.sep)) throw new Error('invalid npm projection archive')
      const resolved = pathToFileURL(archive).href
      const entry = { ...item, resolved, archive }
      const versions = byName.get(item.name) || new Map()
      const other = versions.get(item.version)
      if (other && other.integrity !== item.integrity) throw new Error('conflicting npm projection: ' + item.name)
      versions.set(item.version, entry)
      byName.set(item.name, versions)
      archives.set(resolved, entry)
    }
  }
  const chosen = new Map()
  for (const [name, versions] of byName) {
    const primaries = [...versions.values()].filter(item => item.primary)
    if (primaries.length > 1) throw new Error('conflicting npm producers: ' + name)
    if (primaries.length === 1) chosen.set(name, primaries[0])
    else if (versions.size === 1) chosen.set(name, [...versions.values()][0])
  }
  const select = (name, wanted) => byName.get(name)?.get(wanted) || chosen.get(name)
  const npa = load('npm-package-arg')
  const validPath = require.resolve('@npmcli/arborist/lib/dep-valid.js', { paths: [modules] })
  const valid = require(validPath)
  require.cache[validPath].exports = (child, requested, accept, requestor) => {
    let spec
    try { spec = typeof requested === 'string' ? npa.resolve(child.name, requested) : requested } catch {}
    if (spec?.type === 'alias') spec = spec.subSpec
    if (spec && ['range', 'version', 'tag', 'git', 'remote', 'file'].includes(spec.type)) {
      const entry = select(spec.name, spec.fetchSpec)
      if (entry && child.version === entry.version && [entry.resolved, entry.archive, 'file:'+entry.archive].includes(child.resolved)) return true
    }
    return valid(child, requested, accept, requestor)
  }
  // Supplied runtime nodes are locked by Nix, including nodes absent from
  // the native lock. Keep npm's ordinary checks for every other artifact.
  const validatePath = require.resolve(path.join(modules, '../lib/utils/validate-lockfile.js'))
  const validate = require(validatePath)
  require.cache[validatePath].exports = (virtual, ideal) => validate(virtual, new Map(
    [...ideal].filter(([, node]) => {
      const name = node.package?.name || node.name
      const entry = byName.get(name)?.get(node.version)
      return !entry || ![entry.resolved, entry.archive, 'file:'+entry.archive].includes(node.resolved)
    })
  ))
  const trusted = new WeakMap()
  const pickPath = require.resolve('npm-pick-manifest', { paths: [modules] })
  const pick = require(pickPath)
  require.cache[pickPath].exports = (packument, wanted, options) => {
    const versions = trusted.get(packument)
    const entry = versions && select(packument.name, wanted)
    return pick(packument, entry ? entry.version : wanted, options)
  }
  // Complete fetcher cycles, then patch before the public API captures get.
  const Fetcher = load('pacote/lib/fetcher.js')
  const File = load('pacote/lib/file.js')
  const getFetcher = Fetcher.get
  Fetcher.get = function (requested, options = {}) {
    const spec = typeof requested === 'string' ? npa(requested, options.where) : requested
    const entry = spec && ['git','remote','file'].includes(spec.type) && select(spec.name, spec.fetchSpec)
    if (!entry) return getFetcher.call(this, requested, options)
    const fetcher = new File(entry.resolved, {...options, integrity:entry.integrity, preferOnline:true})
    const manifest = fetcher.manifest.bind(fetcher)
    fetcher.manifest = async () => ({...await manifest(), _resolved:entry.resolved})
    return fetcher
  }
  load('pacote')
  const Shrinkwrap = load('@npmcli/arborist/lib/shrinkwrap.js')
  const readLock = Shrinkwrap.prototype.load
  Shrinkwrap.prototype.load = async function (...args) {
    const result = await readLock.apply(this, args)
    for (const [location, item] of Object.entries(this.data?.packages || {})) {
      if (!location.includes('node_modules/') || item.link || item.inBundle) continue
      const name = item.name || location.split('node_modules/').pop()
      const entry = select(name, item.version)
      if (!entry) continue
      for (const key of ['dependencies', 'optionalDependencies', 'peerDependencies', 'peerDependenciesMeta']) {
        delete item[key]
        if (entry.package[key]) item[key] = { ...entry.package[key] }
      }
      item.version = entry.version
      item.resolved = entry.resolved
      item.integrity = entry.integrity
      delete item.hasInstallScript
    }
    return result
  }
  const Registry = load('pacote/lib/registry.js')
  const symbols = load('pacote/lib/util/protected.js')
  const packument = Registry.prototype.packument
  Registry.prototype.packument = async function () {
    const available = byName.get(this.spec.name)
    if (!available || !select(this.spec.name, this.spec.fetchSpec)) return packument.call(this)
    const versions = {}
    for (const entry of available.values()) versions[entry.version] = {
      ...entry.package,
      dist: { tarball: entry.resolved, integrity: entry.integrity },
    }
    const result = { name: this.spec.name, versions, 'dist-tags': { latest: select(this.spec.name, this.spec.fetchSpec).version } }
    trusted.set(result, available)
    return result
  }
  const tarball = Registry.prototype[symbols.tarballFromResolved]
  Registry.prototype[symbols.tarballFromResolved] = function () {
    const entry = archives.get(this.resolved)
    if (!entry) return tarball.call(this)
    return new File(entry.resolved, { ...this.opts, resolved: entry.resolved, integrity: entry.integrity })[symbols.tarballFromResolved]()
  }
}
module.exports = { activate }
if (process.env.NPM_PURIFIER_INPUT_VIEWS && process.env.NPM_PURIFIER_NPM_MODULES && process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(path.join(process.env.NPM_PURIFIER_NPM_MODULES, '../bin/npm-cli.js'))) {
  activate(JSON.parse(fs.readFileSync(process.env.NPM_PURIFIER_INPUT_VIEWS, 'utf8')), process.env.NPM_PURIFIER_NPM_MODULES)
}
