import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { buildSandbox } from './sandbox.ts'

let dir: string
let real: string
let other: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-sandbox-test-'))
  real = join(dir, 'real')
  other = join(dir, 'other')
  await mkdir(real)
  await mkdir(other)
  await writeFile(join(real, 'Reviewer.synapse'), 'Agent Reviewer [Prompt => "r"];')
  await writeFile(join(real, 'Dev.synapse'), 'Pipeline Dev { old }')
  await writeFile(join(real, 'notes.txt'), 'not a definition')
  await writeFile(join(other, 'Elsewhere.synapse'), 'Agent Elsewhere [Prompt => "e"];')
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

describe('buildSandbox', () => {
  it('copies the definitions and puts the draft among them', async () => {
    const box = await buildSandbox({
      defaultDir: real,
      otherDirs: [other],
      draft: { name: 'New', text: 'Pipeline New {}' },
    })
    try {
      const copy = join(box.env.XDG_CONFIG_HOME, 'synapse-pipeline')
      expect((await readdir(copy)).sort()).toEqual([
        'Dev.synapse',
        'New.synapse',
        'Reviewer.synapse',
      ])
      expect(await readFile(join(copy, 'New.synapse'), 'utf8')).toBe('Pipeline New {}')
      expect(await readdir(box.env.SYNAPSE_PIPELINE_PATH)).toEqual(['Elsewhere.synapse'])
    } finally {
      await box.cleanup()
    }
  })

  it('lets the draft replace the file of its name, and changes nothing real', async () => {
    const box = await buildSandbox({
      defaultDir: real,
      otherDirs: [],
      draft: { name: 'Dev', text: 'Pipeline Dev { new }' },
    })
    try {
      const copy = join(box.env.XDG_CONFIG_HOME, 'synapse-pipeline')
      expect(await readFile(join(copy, 'Dev.synapse'), 'utf8')).toBe('Pipeline Dev { new }')
      expect(await readFile(join(real, 'Dev.synapse'), 'utf8')).toBe('Pipeline Dev { old }')
    } finally {
      await box.cleanup()
    }
  })

  it('holds only the definition files, with no skills folder beside them', async () => {
    await mkdir(join(real, 'skills', 'review-code'), { recursive: true })
    await writeFile(join(real, 'skills', 'review-code', 'SKILL.md'), 'skill text')
    const box = await buildSandbox({
      defaultDir: real,
      otherDirs: [],
      draft: { name: 'New', text: 'x' },
    })
    try {
      const copy = join(box.env.XDG_CONFIG_HOME, 'synapse-pipeline')
      expect((await readdir(copy)).sort()).toEqual([
        'Dev.synapse',
        'New.synapse',
        'Reviewer.synapse',
      ])
    } finally {
      await box.cleanup()
    }
  })

  it('adds an extra file beside the draft, and copes with a directory that is not there', async () => {
    const box = await buildSandbox({
      defaultDir: join(dir, 'missing'),
      otherDirs: [join(dir, 'also-missing')],
      draft: { name: 'Agent_One', text: 'Agent Agent_One [Prompt => "x"];' },
      extra: { name: 'Probe', text: 'Pipeline Probe {}' },
    })
    try {
      const copy = join(box.env.XDG_CONFIG_HOME, 'synapse-pipeline')
      expect((await readdir(copy)).sort()).toEqual(['Agent_One.synapse', 'Probe.synapse'])
    } finally {
      await box.cleanup()
    }
  })

  it('removes the copy when it is cleaned up', async () => {
    const box = await buildSandbox({
      defaultDir: real,
      otherDirs: [],
      draft: { name: 'New', text: 'x' },
    })
    const root = box.env.XDG_CONFIG_HOME
    expect((await stat(root)).isDirectory()).toBe(true)
    await box.cleanup()
    await expect(stat(root)).rejects.toThrow()
  })
})
