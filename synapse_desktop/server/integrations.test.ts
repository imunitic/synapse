import { chmod, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { hookOf, inspectIntegrations, versionOfProgram } from './integrations.ts'

let dir: string
let home: string
let bin: string

const EXE = process.platform === 'win32' ? '.exe' : ''

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-integrations-'))
  home = join(dir, 'home')
  bin = join(dir, 'bin')
  await mkdir(home, { recursive: true })
  await mkdir(bin, { recursive: true })
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

async function put(file: string, text: string): Promise<void> {
  await mkdir(join(file, '..'), { recursive: true })
  await writeFile(file, text)
}

// A hook program and a `synapse` beside it, in `where`.
async function program(where: string): Promise<string> {
  await mkdir(where, { recursive: true })
  await put(join(where, 'synapse' + EXE), '')
  await put(join(where, 'synapse-hook' + EXE), '')
  return join(where, 'synapse-hook' + EXE)
}

function claude(hook: string): string {
  return JSON.stringify({
    hooks: {
      Stop: [{ hooks: [{ type: 'command', command: 'other-tool stop' }] }],
      SessionStart: [{ hooks: [{ type: 'command', command: `${hook} session-start` }] }],
    },
  })
}

describe('the hook a harness runs', () => {
  it('is read from the settings of Claude Code, whatever else is there', async () => {
    expect(await hookOf('Claude', home)).toBeNull()
    await put(join(home, '.claude', 'settings.json'), claude('/opt/synapse/bin/synapse-hook'))
    expect(await hookOf('Claude', home)).toBe('/opt/synapse/bin/synapse-hook')
  })

  it('is read from the hooks of Codex', async () => {
    await put(join(home, '.codex', 'hooks.json'), claude('/c/bin/synapse-hook'))
    expect(await hookOf('Codex', home)).toBe('/c/bin/synapse-hook')
  })

  it('is read from the plugin of OpenCode, where the path is baked in', async () => {
    await put(
      join(home, '.config', 'opencode', 'plugin', 'synapse.js'),
      'const HOOK_BIN = process.env.SYNAPSE_HOOK_BIN || "/o/bin/synapse-hook"\n',
    )
    expect(await hookOf('Opencode', home)).toBe('/o/bin/synapse-hook')
  })

  it('is not found in a plugin that was never given one, or in files that are not JSON', async () => {
    await put(
      join(home, '.config', 'opencode', 'plugin', 'synapse.js'),
      'const HOOK_BIN = process.env.SYNAPSE_HOOK_BIN || "__SYNAPSE_HOOK_BIN__"\n',
    )
    expect(await hookOf('Opencode', home)).toBeNull()
    await put(join(home, '.claude', 'settings.json'), '{ not json')
    expect(await hookOf('Claude', home)).toBeNull()
    await put(join(home, '.claude', 'settings.json'), '{"hooks":{"Stop":"nope"}}')
    expect(await hookOf('Claude', home)).toBeNull()
  })

  it('is a program named synapse-hook and not one that only ends so', async () => {
    await put(join(home, '.claude', 'settings.json'), claude('/x/not-synapse-hook'))
    expect(await hookOf('Claude', home)).toBeNull()
  })
})

describe('what each harness has', () => {
  const versions: Record<string, string> = {}
  const versionOf = (program: string): Promise<string | null> =>
    Promise.resolve(versions[program] ?? null)

  beforeEach(() => {
    for (const key of Object.keys(versions)) delete versions[key]
  })

  it('is absent with no hook, and says what the app would install', async () => {
    const mine = await program(join(dir, 'mine'))
    versions[join(dir, 'mine', 'synapse' + EXE)] = '1.2.0'
    const result = await inspectIntegrations({
      env: { PATH: join(dir, 'mine') },
      home,
      versionOf,
    })
    expect(result.bundled).toMatchObject({ hook: mine, version: '1.2.0' })
    expect(result.harnesses.map((h) => [h.harness, h.state])).toEqual([
      ['Claude', 'absent'],
      ['Codex', 'absent'],
      ['Opencode', 'absent'],
    ])
  })

  it('is current when the hook is the one of the Synapse the app has, or its version', async () => {
    const mine = await program(join(dir, 'mine'))
    const other = await program(join(dir, 'other'))
    versions[join(dir, 'mine', 'synapse' + EXE)] = '1.2.0'
    versions[join(dir, 'other', 'synapse' + EXE)] = '1.2.0'
    await put(join(home, '.claude', 'settings.json'), claude(mine))
    await put(join(home, '.codex', 'hooks.json'), claude(other))
    const result = await inspectIntegrations({ env: { PATH: join(dir, 'mine') }, home, versionOf })
    expect(result.harnesses.find((h) => h.harness === 'Claude')).toMatchObject({
      state: 'current',
      hook: mine,
      version: '1.2.0',
    })
    expect(result.harnesses.find((h) => h.harness === 'Codex')?.state).toBe('current')
  })

  it('is different when the hook is of another copy of another version', async () => {
    await program(join(dir, 'mine'))
    const old = await program(join(dir, 'old'))
    versions[join(dir, 'mine', 'synapse' + EXE)] = '1.2.0'
    versions[join(dir, 'old', 'synapse' + EXE)] = '1.0.0'
    await put(join(home, '.claude', 'settings.json'), claude(old))
    const result = await inspectIntegrations({ env: { PATH: join(dir, 'mine') }, home, versionOf })
    expect(result.harnesses[0]).toMatchObject({ state: 'different', version: '1.0.0' })
  })

  it('is broken when the hook it names is not there', async () => {
    await put(join(home, '.claude', 'settings.json'), claude(join(dir, 'gone', 'synapse-hook')))
    const result = await inspectIntegrations({ env: { PATH: '' }, home, versionOf })
    expect(result.harnesses[0]).toMatchObject({ state: 'broken', version: null })
  })

  it("is installed when there is no Synapse of the app's own to compare with", async () => {
    const theirs = await program(join(dir, 'theirs'))
    await put(join(home, '.claude', 'settings.json'), claude(theirs))
    const result = await inspectIntegrations({ env: { PATH: '' }, home, versionOf })
    expect(result.bundled.hook).toBeNull()
    expect(result.harnesses[0]?.state).toBe('installed')
  })
})

describe('the version a program says', () => {
  it.skipIf(process.platform === 'win32')('is what follows its name', async () => {
    const script = join(bin, 'synapse')
    await writeFile(script, '#!/bin/sh\necho "synapse 3.4.5-rc1"\n')
    await chmod(script, 0o755)
    expect(await versionOfProgram(script)).toBe('3.4.5-rc1')
  })

  it('is nothing for a program that is not there or says something else', async () => {
    expect(await versionOfProgram(join(bin, 'missing'))).toBeNull()
  })
})
