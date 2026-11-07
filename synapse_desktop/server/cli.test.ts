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

  it('allows only config of synapse, and only its list, set and unset', () => {
    expect(refuseCli('synapse', ['vault-read', 'Index.md'])).toMatch(/not allowed/)
    expect(refuseCli('synapse', ['config', 'list'])).toBeNull()
    expect(refuseCli('synapse', ['config', 'list', '--format', 'json'])).toBeNull()
    expect(refuseCli('synapse', ['config', 'set', 'SYNAPSE_VAULT_DIR', '/a b'])).toBeNull()
    expect(refuseCli('synapse', ['config', 'set', 'SYNAPSE_VAULT_PUSH_EVERY', '--x'])).toBeNull()
    expect(refuseCli('synapse', ['config', 'unset', 'SYNAPSE_VAULT_DIR'])).toBeNull()
  })

  it('refuses the rest of config: other actions, bad names, wrong counts', () => {
    expect(refuseCli('synapse', ['config'])).toMatch(/list, set or unset/)
    expect(refuseCli('synapse', ['config', 'frob'])).toMatch(/list, set or unset/)
    expect(refuseCli('synapse', ['config', 'list', '--format', 'xml'])).toMatch(/only --format/)
    expect(refuseCli('synapse', ['config', 'list', 'extra'])).toMatch(/only --format/)
    expect(refuseCli('synapse', ['config', 'set', 'lower_case', 'v'])).toMatch(/name and a value/)
    expect(refuseCli('synapse', ['config', 'set', '--help', 'v'])).toMatch(/name and a value/)
    expect(refuseCli('synapse', ['config', 'set', 'SYNAPSE_X'])).toMatch(/name and a value/)
    expect(refuseCli('synapse', ['config', 'unset'])).toMatch(/setting name/)
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
