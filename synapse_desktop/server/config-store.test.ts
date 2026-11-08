import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { defaultConfig } from '../shared/calls.ts'
import { handleCall, type Context } from './calls.ts'
import { loadConfig, loadStoredConfig } from './config-store.ts'

let dir: string
let file: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-config-'))
  file = join(dir, 'config.json')
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

function contextFor(): Context {
  return {
    environment: { env: { XDG_CONFIG_HOME: dir }, home: dir },
    configFile: file,
    runCli: () => Promise.reject(new Error('not used')),
    runs: { start: () => Promise.reject(new Error('not used')), stop: () => undefined },
    agent: () => Promise.reject(new Error('not used')),
    noteSession: () => Promise.reject(new Error('not used')),
  }
}

describe('the configuration file', () => {
  it('reads a file written before variables and recent vaults existed', async () => {
    await writeFile(
      file,
      JSON.stringify({ workDir: '/w', definitionPaths: [], defaultHarness: 'Codex' }),
    )
    expect(await loadStoredConfig(file)).toEqual({
      workDir: '/w',
      definitionPaths: [],
      defaultHarness: 'Codex',
      env: {},
      recentVaults: [],
      terminalFolder: null,
      defaultModels: {},
      graphRepos: {},
    })
  })

  it('is the default when there is no file', async () => {
    expect(await loadStoredConfig(file)).toEqual(defaultConfig)
  })
})

describe('setConfig', () => {
  it('keeps the variables when another setting changes', async () => {
    const context = contextFor()
    await handleCall('setConfig', { patch: { env: { SYNAPSE_X: '1' } } }, context)
    await handleCall('setConfig', { patch: { workDir: '/w' } }, context)
    expect(await loadStoredConfig(file)).toMatchObject({ workDir: '/w', env: { SYNAPSE_X: '1' } })
  })

  it('refuses a variable with a name no shell takes, and too many variables', async () => {
    const context = contextFor()
    for (const env of [{ 'BAD NAME': '1' }, { '1X': '1' }, { 'A=B': '1' }, { '': '1' }]) {
      await expect(handleCall('setConfig', { patch: { env } }, context)).rejects.toMatchObject({
        status: 400,
      })
    }
    const many = Object.fromEntries(Array.from({ length: 65 }, (_, i) => [`V${i}`, 'x']))
    await expect(handleCall('setConfig', { patch: { env: many } }, context)).rejects.toMatchObject({
      status: 400,
    })
  })

  it('keeps at most eight recent vaults', async () => {
    const context = contextFor()
    const nine = Array.from({ length: 9 }, (_, i) => `/v${i}`)
    await expect(
      handleCall('setConfig', { patch: { recentVaults: nine } }, context),
    ).rejects.toMatchObject({ status: 400 })
  })
})

describe('the work directory in force', () => {
  const at = (env: Record<string, string>, home = '/h') => ({ env, home })

  it('is the variable of the app, else of the server, else the saved one, else the default', async () => {
    expect((await loadConfig(file, at({}))).workDir).toBe(join('/h', '.cache', 'synapse', 'work'))
    expect((await loadConfig(file, at({ SYNAPSE_WORK_DIR: '/started' }))).workDir).toBe('/started')

    await writeFile(file, JSON.stringify({ ...defaultConfig, workDir: '/saved' }))
    expect((await loadConfig(file, at({}))).workDir).toBe('/saved')
    expect((await loadConfig(file, at({ SYNAPSE_WORK_DIR: '/started' }))).workDir).toBe('/started')

    await writeFile(
      file,
      JSON.stringify({ ...defaultConfig, workDir: '/saved', env: { SYNAPSE_WORK_DIR: '/app' } }),
    )
    expect((await loadConfig(file, at({ SYNAPSE_WORK_DIR: '/started' }))).workDir).toBe('/app')
  })

  it('is none only when there is no home to put the default in', async () => {
    expect((await loadConfig(file, at({}, ''))).workDir).toBeNull()
  })

  it('does not replace the saved one when another setting is changed', async () => {
    const context = contextFor()
    context.environment.env.SYNAPSE_WORK_DIR = '/started'
    await handleCall('setConfig', { patch: { workDir: '/saved' } }, context)
    const answer = (await handleCall(
      'setConfig',
      { patch: { defaultHarness: 'Codex' } },
      context,
    )) as {
      workDir: string
    }
    expect(answer.workDir).toBe('/started')
    expect((await loadStoredConfig(file)).workDir).toBe('/saved')
  })

  it('is not from an empty variable', async () => {
    expect((await loadConfig(file, at({ SYNAPSE_WORK_DIR: '' }))).workDir).toBe(
      join('/h', '.cache', 'synapse', 'work'),
    )
  })
})
