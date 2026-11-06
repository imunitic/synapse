import { describe, expect, it } from 'vitest'
import { delimiter } from 'node:path'
import { defaultConfig } from '../shared/calls.ts'
import { cliEnvironment, refuseCli } from './cli.ts'

describe('refuseCli', () => {
  it('allows the read-only and housekeeping subcommands of synapse-pipeline', () => {
    for (const sub of ['check', 'show', 'list', 'info', 'cleanup']) {
      expect(refuseCli('synapse-pipeline', [sub, 'x'])).toBeNull()
    }
  })

  it('refuses run, which is started through startRun', () => {
    expect(refuseCli('synapse-pipeline', ['run', 'p'])).toMatch(/not allowed/)
  })

  it('refuses every subcommand of synapse until one is added', () => {
    expect(refuseCli('synapse', ['vault-read', 'Index.md'])).toMatch(/not allowed/)
  })

  it('refuses a call with no subcommand and one that starts with a flag', () => {
    expect(refuseCli('synapse-pipeline', [])).toMatch(/subcommand is required/)
    expect(refuseCli('synapse-pipeline', ['--help'])).toMatch(/not allowed/)
  })

  it('refuses too many arguments, a long one and a NUL', () => {
    expect(refuseCli('synapse-pipeline', ['show', ...Array<string>(32).fill('a')])).toMatch(
      /too many/,
    )
    expect(refuseCli('synapse-pipeline', ['show', 'a'.repeat(5000)])).toMatch(/too long/)
    expect(refuseCli('synapse-pipeline', ['show', 'a\0b'])).toMatch(/too long or holds a NUL/)
  })
})

describe('cliEnvironment', () => {
  it('leaves the environment as it is when the app sets nothing', () => {
    expect(cliEnvironment({ A: '1' }, defaultConfig)).toEqual({ A: '1' })
  })

  it('sets the work directory', () => {
    const env = cliEnvironment({}, { ...defaultConfig, workDir: '/w' })
    expect(env.SYNAPSE_WORK_DIR).toBe('/w')
  })

  it('puts the definition directories of the app before the inherited ones', () => {
    const base = { SYNAPSE_PIPELINE_PATH: `/x${delimiter}/y` }
    const env = cliEnvironment(base, { ...defaultConfig, definitionPaths: ['/mine'] })
    expect(env.SYNAPSE_PIPELINE_PATH).toBe(['/mine', '/x', '/y'].join(delimiter))
  })

  it('does not change the environment it is given', () => {
    const base = { SYNAPSE_PIPELINE_PATH: '/x' }
    cliEnvironment(base, { ...defaultConfig, definitionPaths: ['/mine'] })
    expect(base.SYNAPSE_PIPELINE_PATH).toBe('/x')
  })
})
