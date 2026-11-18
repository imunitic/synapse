import { mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { defaultConfig } from '../shared/calls.ts'
import { allowedRoots, definitionDirs, OutsideRoots, resolveInside } from './roots.ts'

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-roots-'))
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

describe('resolveInside', () => {
  it('accepts a file inside a root', async () => {
    const root = join(dir, 'root')
    await mkdir(root)
    await writeFile(join(root, 'a.synapse'), 'x')
    expect(await resolveInside(join(root, 'a.synapse'), [root])).toContain('a.synapse')
  })

  it('refuses a file outside every root', async () => {
    const root = join(dir, 'root')
    await mkdir(root)
    await writeFile(join(dir, 'secret'), 'x')
    await expect(resolveInside(join(dir, 'secret'), [root])).rejects.toBeInstanceOf(OutsideRoots)
  })

  it('refuses a path that climbs out with ..', async () => {
    const root = join(dir, 'root')
    await mkdir(root)
    await writeFile(join(dir, 'secret'), 'x')
    await expect(resolveInside(join(root, '..', 'secret'), [root])).rejects.toBeInstanceOf(
      OutsideRoots,
    )
  })

  it('refuses a symbolic link that leads out of the root', async () => {
    const root = join(dir, 'root')
    await mkdir(root)
    await writeFile(join(dir, 'secret'), 'x')
    await symlink(join(dir, 'secret'), join(root, 'link'))
    await expect(resolveInside(join(root, 'link'), [root])).rejects.toBeInstanceOf(OutsideRoots)
  })

  it('refuses a sibling whose name starts with the root name', async () => {
    const root = join(dir, 'root')
    const sibling = join(dir, 'root-other')
    await mkdir(root)
    await mkdir(sibling)
    await writeFile(join(sibling, 'f'), 'x')
    await expect(resolveInside(join(sibling, 'f'), [root])).rejects.toBeInstanceOf(OutsideRoots)
  })

  it('refuses a relative path', async () => {
    await expect(resolveInside('a.synapse', [dir])).rejects.toBeInstanceOf(OutsideRoots)
  })
})

describe('allowedRoots', () => {
  const environment = { env: { SYNAPSE_PIPELINE_PATH: '/x/one:/x/two' }, home: '/home/u' }

  it('lists SYNAPSE_PIPELINE_PATH, the default directory and the configured ones', () => {
    const config = { ...defaultConfig, definitionPaths: ['/y/three'] }
    expect(definitionDirs(config, environment)).toEqual([
      '/x/one',
      '/x/two',
      '/home/u/.config/synapse-pipeline',
      '/y/three',
    ])
  })

  it('uses XDG_CONFIG_HOME for the default directory when it is set', () => {
    const env = { env: { XDG_CONFIG_HOME: '/xdg' }, home: '/home/u' }
    expect(definitionDirs(defaultConfig, env)).toEqual(['/xdg/synapse-pipeline'])
  })

  it('reaches only the pipelines folder of the work directory', () => {
    const config = { ...defaultConfig, workDir: '/work' }
    expect(allowedRoots(config, { env: {}, home: '/home/u' })).toContain('/work/pipelines')
    expect(allowedRoots(config, { env: {}, home: '/home/u' })).not.toContain('/work')
  })
})
