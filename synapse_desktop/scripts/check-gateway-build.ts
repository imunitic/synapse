// Build-time smoke test for the *real* Vite output, not synthetic fixtures.
// Does not start a gateway listener or enable remote hosting.
import assert from 'node:assert/strict'
import { join } from 'node:path'
import { loadViteProtectedAssets } from '../server/gateway-vite-assets.ts'

const dist = join(import.meta.dirname, '..', 'dist')
const assets = await loadViteProtectedAssets(dist)
const index = assets.get('/')
assert.ok(index, 'Vite build is missing an authenticated index')
const html = index.content.toString()
assert.match(html, /<div id="root"><\/div>/, 'Vite index is missing the app root')
assert.ok(
  [...assets.keys()].some((path) => path.startsWith('/assets/') && path.endsWith('.js')),
  'Vite build is missing a protected JavaScript bundle',
)
assert.ok(
  [...assets.keys()].some((path) => path.startsWith('/assets/') && path.endsWith('.css')),
  'Vite build is missing protected CSS',
)
assert.ok(!assets.has('/.vite/manifest.json'), 'internal Vite manifest must never be served')
console.log(`Verified ${assets.size} protected production assets against Vite output`)
