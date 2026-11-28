import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { loadViteProtectedAssets } from './gateway-vite-assets.ts'

const directories: string[] = []
const entry = { file: 'assets/index-a1.js', css: ['assets/index-a1.css'] }

async function fixture(manifest: object = { 'index.html': entry }): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), 'synapse-vite-'))
  directories.push(root)
  await mkdir(join(root, '.vite'))
  await mkdir(join(root, 'assets'))
  await writeFile(join(root, 'index.html'), '<html>private Synapse</html>')
  await writeFile(join(root, '.vite', 'manifest.json'), JSON.stringify(manifest))
  await writeFile(join(root, 'assets', 'index-a1.js'), 'console.log("private")')
  await writeFile(join(root, 'assets', 'index-a1.css'), 'body{color:white}')
  return root
}

afterEach(async () => {
  await Promise.all(directories.splice(0).map((path) => rm(path, { recursive: true, force: true })))
})

describe('private Vite build asset loader', () => {
  it('loads exactly the built entrypoint and allowlisted script and CSS', async () => {
    const root = await fixture()
    await writeFile(join(root, 'assets', 'not-listed.js'), 'should not be served')
    const assets = await loadViteProtectedAssets(root)
    expect([...assets.keys()]).toEqual(['/', '/assets/index-a1.js', '/assets/index-a1.css'])
    expect(assets.get('/')?.content.toString()).toContain('private Synapse')
    expect(assets.get('/assets/index-a1.js')?.contentType).toContain('javascript')
    expect(assets.has('/assets/not-listed.js')).toBe(false)
    expect(assets.has('/.vite/manifest.json')).toBe(false)
  })

  it('accepts Vite-rewritten HTML when every referenced resource is protected', async () => {
    const root = await fixture()
    await writeFile(
      join(root, 'index.html'),
      '<html><script type="module" src="/assets/index-a1.js"></script><link rel="stylesheet" href="/assets/index-a1.css"></html>',
    )
    const assets = await loadViteProtectedAssets(root)
    expect(assets.has('/assets/index-a1.js')).toBe(true)
    expect(assets.has('/assets/index-a1.css')).toBe(true)
  })

  it('refuses HTML references to unlisted or public build resources', async () => {
    for (const reference of ['/assets/unlisted.js', '/favicon.svg', 'https://other.example/a.js']) {
      const root = await fixture()
      await writeFile(join(root, 'index.html'), `<html><script src="${reference}"></script></html>`)
      await expect(loadViteProtectedAssets(root)).rejects.toThrow(
        'Vite HTML references an unserved asset',
      )
    }
  })

  it('refuses manifest entry files that escape the build directory', async () => {
    for (const filename of [
      '../secrets.txt',
      'assets/../secret.js',
      '/etc/passwd',
      'assets/%2e%2e.js',
    ]) {
      const root = await fixture({ 'index.html': { file: filename } })
      await expect(loadViteProtectedAssets(root)).rejects.toThrow('unsafe Vite asset path')
    }
  })

  it('rejects malformed, missing, and wrongly typed manifest entries', async () => {
    const cases: object[] = [
      {},
      { 'index.html': { file: 12 } },
      { 'index.html': { file: 'assets/index-a1.js', css: 'assets/index-a1.css' } },
      { 'index.html': null },
    ]
    for (const manifest of cases) {
      const root = await fixture(manifest)
      await expect(loadViteProtectedAssets(root)).rejects.toThrow()
    }
  })

  it('rejects filesystem symlinks leading outside the build directory', async () => {
    const root = await fixture({ 'index.html': { file: 'assets/external.js' } })
    const outside = await mkdtemp(join(tmpdir(), 'synapse-secret-'))
    directories.push(outside)
    await writeFile(join(outside, 'private.js'), 'secret')
    await symlink(join(outside, 'private.js'), join(root, 'assets', 'external.js'))
    await expect(loadViteProtectedAssets(root)).rejects.toThrow('asset symlink escapes')
  })

  it('rejects oversized assets before reading their contents', async () => {
    const root = await fixture()
    await writeFile(join(root, 'assets', 'index-a1.js'), Buffer.alloc(8 * 1024 * 1024 + 1))
    await expect(loadViteProtectedAssets(root)).rejects.toThrow('invalid build asset size')
  })
})
