import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { buildSandbox } from './sandbox.ts'

let dir: string
let real: string
let other: string
let skills: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-sandbox-test-'))
  real = join(dir, 'real')
  other = join(dir, 'other')
  skills = join(real, 'skills')
  await mkdir(join(skills, 'review-code'), { recursive: true })
  await mkdir(other)
  await writeFile(join(real, 'Reviewer.synapse'), 'Agent Reviewer [Prompt => "r"];')
  await writeFile(join(real, 'Dev.synapse'), 'Pipeline Dev { old }')
  await writeFile(join(real, 'notes.txt'), 'not a definition')
  await writeFile(join(other, 'Elsewhere.synapse'), 'Agent Elsewhere [Prompt => "e"];')
  await writeFile(join(skills, 'review-code', 'SKILL.md'), 'skill text')
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

describe('buildSandbox', () => {
  it('copies the definitions and puts the draft among them', async () => {
    const box = await buildSandbox({
      defaultDir: real,
      otherDirs: [other],
      skillsDir: skills,
      draft: { name: 'New', text: 'Pipeline New {}' },
    })
    try {
      const copy = join(box.env.XDG_CONFIG_HOME, 'synapse-pipeline')
      expect((await readdir(copy)).sort()).toEqual([
        'Dev.synapse',
        'New.synapse',
        'Reviewer.synapse',
        'skills',
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
      skillsDir: null,
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

  it('links the skills, which are then readable through the copy', async () => {
    const box = await buildSandbox({
      defaultDir: real,
      otherDirs: [],
      skillsDir: skills,
      draft: { name: 'New', text: 'x' },
    })
    try {
      const linked = join(
        box.env.XDG_CONFIG_HOME,
        'synapse-pipeline',
        'skills',
        'review-code',
        'SKILL.md',
      )
      expect(await readFile(linked, 'utf8')).toBe('skill text')
    } finally {
      await box.cleanup()
    }
  })

  it('adds an extra file beside the draft, and copes with a directory that is not there', async () => {
    const box = await buildSandbox({
      defaultDir: join(dir, 'missing'),
      otherDirs: [join(dir, 'also-missing')],
      skillsDir: null,
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
      skillsDir: null,
      draft: { name: 'New', text: 'x' },
    })
    const root = box.env.XDG_CONFIG_HOME
    expect((await stat(root)).isDirectory()).toBe(true)
    await box.cleanup()
    await expect(stat(root)).rejects.toThrow()
  })
})
