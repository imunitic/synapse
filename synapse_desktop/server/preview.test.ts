import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { CallError, handleCall, type Context } from './calls.ts'
import type { CliRun } from './cli.ts'

let dir: string
let defaults: string
let seen: { run: CliRun; files: string[]; draft: string | null }[]
let context: Context

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-preview-'))
  defaults = join(dir, 'xdg', 'synapse-pipeline')
  await mkdir(defaults, { recursive: true })
  await writeFile(join(defaults, 'Reviewer.synapse'), 'Agent Reviewer [Prompt => "r"];')
  seen = []
  context = {
    environment: { env: { XDG_CONFIG_HOME: join(dir, 'xdg') }, home: dir },
    configFile: join(dir, 'config.json'),
    // Looks at what the program would see while it is asked.
    runCli: async (run) => {
      const copy = join(run.env?.XDG_CONFIG_HOME ?? '', 'synapse-pipeline')
      const files = (await readdir(copy)).sort()
      const name = run.args[1] ?? ''
      const draft = await readFile(join(copy, `${name}.synapse`), 'utf8').catch(() => null)
      seen.push({ run, files, draft })
      return { code: 0, stdout: '{}', stderr: '' }
    },
    agent: () => Promise.reject(new Error('not used')),
    runs: {
      start: () => Promise.reject(new Error('not used')),
      stop: () => undefined,
    },
  }
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

describe('previewDraft', () => {
  it('asks the program to describe a pipeline among a copy of the definitions', async () => {
    await handleCall(
      'previewDraft',
      { draft: { kind: 'pipeline', name: 'New_One', text: 'Pipeline New_One {}' } },
      context,
    )
    const [call] = seen
    expect(call?.run.args).toEqual(['show', 'New_One', '--format', 'json'])
    expect(call?.files).toEqual(['New_One.synapse', 'Reviewer.synapse'])
    expect(call?.draft).toBe('Pipeline New_One {}')
  })

  it('points the program at the copy only and at nothing of the real configuration', async () => {
    await handleCall('previewDraft', { draft: { kind: 'pipeline', name: 'P', text: 'x' } }, context)
    const run = seen[0]?.run
    expect(run?.env?.XDG_CONFIG_HOME).not.toBe(join(dir, 'xdg'))
    expect(run?.env?.XDG_CONFIG_HOME).toContain('synapse-desktop-draft-')
    expect(run?.config).toMatchObject({ workDir: null, definitionPaths: [] })
  })

  it('removes the copy once the program has answered, and leaves the real files as they were', async () => {
    await handleCall('previewDraft', { draft: { kind: 'pipeline', name: 'P', text: 'x' } }, context)
    const root = seen[0]?.run.env?.XDG_CONFIG_HOME ?? ''
    await expect(stat(root)).rejects.toThrow()
    expect(await readdir(defaults)).toEqual(['Reviewer.synapse'])
  })

  it('checks a pipeline that stands for the others when the draft is a system or an agent', async () => {
    await handleCall(
      'previewDraft',
      { draft: { kind: 'agent', name: 'Tester', text: 'Agent Tester [Prompt => ];' } },
      context,
    )
    const call = seen[0]
    expect(call?.run.args[0]).toBe('check')
    expect(call?.run.args[1]).toMatch(/^Draft_Probe_[0-9a-f]{6}$/)
    expect(call?.files).toContain('Tester.synapse')
    expect(call?.files.some((f) => f.startsWith('Draft_Probe_'))).toBe(true)
  })

  it('refuses a name that is not an identifier, so that it cannot name a path', async () => {
    for (const name of ['../x', 'a b', '', '1abc', 'a/b']) {
      await expect(
        handleCall('previewDraft', { draft: { kind: 'pipeline', name, text: 'x' } }, context),
      ).rejects.toThrow(/invalid parameters/)
    }
    expect(seen).toEqual([])
  })
})

describe('writeDefinition', () => {
  it('makes the file in the default definition directory', async () => {
    const result = await handleCall(
      'writeDefinition',
      { kind: 'definition', name: 'Fresh', text: 'Agent Fresh [Prompt => "x"];' },
      context,
    )
    expect(result).toEqual({ path: join(defaults, 'Fresh.synapse') })
    expect(await readFile(join(defaults, 'Fresh.synapse'), 'utf8')).toBe(
      'Agent Fresh [Prompt => "x"];',
    )
  })

  it('never replaces a file', async () => {
    await expect(
      handleCall('writeDefinition', { kind: 'definition', name: 'Reviewer', text: 'x' }, context),
    ).rejects.toMatchObject({ status: 409 })
    expect(await readFile(join(defaults, 'Reviewer.synapse'), 'utf8')).toBe(
      'Agent Reviewer [Prompt => "r"];',
    )
  })

  it('makes a skill as a directory with a SKILL.md, in a skills directory that did not exist', async () => {
    const text = '---\nname: do-it\ndescription: Does it.\n---\n'
    const result = await handleCall(
      'writeDefinition',
      { kind: 'skill', name: 'do-it', text },
      context,
    )
    expect(result).toEqual({ path: join(defaults, 'skills', 'do-it', 'SKILL.md') })
    expect(await readFile(join(defaults, 'skills', 'do-it', 'SKILL.md'), 'utf8')).toBe(text)
  })

  it('refuses names that are not the form of a definition or a skill, so that none can name a path', async () => {
    const bad = [
      { kind: 'definition', name: '../escape', text: 'x' },
      { kind: 'definition', name: 'has space', text: 'x' },
      { kind: 'skill', name: 'Upper', text: 'x' },
      { kind: 'skill', name: '../x', text: 'x' },
      { kind: 'skill', name: 'a--b', text: 'x' },
      { kind: 'skill', name: '-a', text: 'x' },
    ]
    for (const item of bad) {
      await expect(handleCall('writeDefinition', item, context)).rejects.toThrow(
        /invalid parameters/,
      )
    }
    expect(await readdir(defaults)).toEqual(['Reviewer.synapse'])
  })
})

describe('saveDefinition', () => {
  async function fileIn(sub: string, name: string, text: string): Promise<string> {
    const folder = join(dir, sub)
    await mkdir(folder, { recursive: true })
    const path = join(folder, name)
    await writeFile(path, text)
    return path
  }

  it('replaces the text of a definition when the file is as it was read', async () => {
    const path = await fileIn('xdg/synapse-pipeline', 'Old.synapse', 'Agent Old [Prompt => "a"];')
    await handleCall(
      'saveDefinition',
      { path, previous: 'Agent Old [Prompt => "a"];', text: 'Agent Old [Prompt => "b"];' },
      context,
    )
    expect(await readFile(path, 'utf8')).toBe('Agent Old [Prompt => "b"];')
  })

  it('refuses when the file has changed since it was read', async () => {
    const path = await fileIn('xdg/synapse-pipeline', 'Old.synapse', 'changed elsewhere')
    await expect(
      handleCall('saveDefinition', { path, previous: 'what was read', text: 'x' }, context),
    ).rejects.toMatchObject({ status: 409 })
    expect(await readFile(path, 'utf8')).toBe('changed elsewhere')
  })

  it('saves the SKILL.md of a skill', async () => {
    const path = await fileIn('xdg/synapse-pipeline/skills/a-skill', 'SKILL.md', 'one')
    await handleCall('saveDefinition', { path, previous: 'one', text: 'two' }, context)
    expect(await readFile(path, 'utf8')).toBe('two')
  })

  it('refuses any other file, and a file outside the definition directories', async () => {
    const other = await fileIn('xdg/synapse-pipeline', 'notes.txt', 'x')
    const outside = await fileIn('elsewhere', 'Out.synapse', 'x')
    for (const path of [other, outside]) {
      await expect(
        handleCall('saveDefinition', { path, previous: 'x', text: 'y' }, context),
      ).rejects.toBeInstanceOf(CallError)
      expect(await readFile(path, 'utf8')).toBe('x')
    }
  })

  it('does not reach into the records of runs', async () => {
    await handleCall('setConfig', { patch: { workDir: join(dir, 'work') } }, context)
    const path = await fileIn('work/pipelines/exec-1/definitions', 'Copy.synapse', 'x')
    await expect(
      handleCall('saveDefinition', { path, previous: 'x', text: 'y' }, context),
    ).rejects.toMatchObject({ status: 403 })
  })
})
