import { describe, expect, it } from 'vitest'
import { refuseCli } from './cli.ts'

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
