import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { CallError, handleCall, type Context } from './calls.ts'
import { inspectVault } from './vault.ts'

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-vault-'))
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

async function note(path: string): Promise<void> {
  await mkdir(join(dir, path, '..'), { recursive: true })
  await writeFile(join(dir, path), '# note\n')
}

describe('inspectVault', () => {
  it('says a folder that is not there is not there', async () => {
    expect(await inspectVault(join(dir, 'nowhere'))).toEqual({
      exists: false,
      hasIndex: false,
      isGit: false,
      notes: 0,
      capped: false,
    })
  })

  it('says a file is not a folder', async () => {
    await note('plain.md')
    expect((await inspectVault(join(dir, 'plain.md'))).exists).toBe(false)
  })

  it('counts the notes of a vault, in every folder, and finds its index and git', async () => {
    await note('Index.md')
    await note('designs/a.md')
    await note('designs/deep/b.md')
    await note('readme.txt')
    await mkdir(join(dir, '.git'))
    expect(await inspectVault(dir)).toEqual({
      exists: true,
      hasIndex: true,
      isGit: true,
      notes: 3,
      capped: false,
    })
  })

  it('leaves out the folders that start with a dot', async () => {
    await note('a.md')
    await note('.obsidian/workspace.md')
    await note('.git/notes.md')
    expect((await inspectVault(dir)).notes).toBe(1)
  })

  it('has no index or git when there are none', async () => {
    await note('a.md')
    expect(await inspectVault(dir)).toMatchObject({ exists: true, hasIndex: false, isGit: false })
  })
})

describe('the inspectVault call', () => {
  // The folder the test makes is the home folder of this context.
  const context = {
    get environment() {
      return { env: {}, home: dir }
    },
  } as unknown as Context

  it('refuses a path that is not absolute, and an empty one', async () => {
    await expect(
      handleCall('inspectVault', { path: 'relative/dir' }, context),
    ).rejects.toMatchObject({
      status: 400,
    })
    await expect(handleCall('inspectVault', { path: '' }, context)).rejects.toBeInstanceOf(
      CallError,
    )
  })

  it('answers for an absolute path', async () => {
    await note('a.md')
    expect(await handleCall('inspectVault', { path: dir }, context)).toMatchObject({
      path: dir,
      exists: true,
      notes: 1,
    })
  })

  it('takes ~ for the home folder and says which folder that made it', async () => {
    await mkdir(join(dir, 'vault'))
    await note('vault/a.md')
    expect(await handleCall('inspectVault', { path: '~/vault' }, context)).toMatchObject({
      path: join(dir, 'vault'),
      exists: true,
      notes: 1,
    })
    expect(await handleCall('inspectVault', { path: '~' }, context)).toMatchObject({ path: dir })
  })
})
