import { describe, expect, it } from 'vitest'
import { effortSchema, effortsOf, isEffortFor } from './efforts.ts'

describe('the efforts of the harnesses', () => {
  it('Claude offers its five efforts', () => {
    expect(effortsOf('Claude')).toEqual(['low', 'medium', 'high', 'xhigh', 'max'])
    for (const effort of ['low', 'medium', 'high', 'xhigh', 'max']) {
      expect(isEffortFor('Claude', effort)).toBe(true)
    }
    expect(isEffortFor('Claude', 'minimal')).toBe(false)
  })

  it('Codex offers minimal and max but not an unknown name', () => {
    expect(isEffortFor('Codex', 'minimal')).toBe(true)
    expect(isEffortFor('Codex', 'max')).toBe(true)
    expect(isEffortFor('Codex', 'ultra')).toBe(true)
    expect(isEffortFor('Codex', 'extreme')).toBe(false)
  })

  it('OpenCode takes any variant name and has no list', () => {
    expect(effortsOf('Opencode')).toBeNull()
    expect(isEffortFor('Opencode', 'high')).toBe(true)
    expect(isEffortFor('Opencode', 'Thinking-2.5_max')).toBe(true)
    expect(isEffortFor('Opencode', '')).toBe(false)
  })

  it('a variant may not start with a dash or hold a #', () => {
    expect(isEffortFor('Opencode', '-high')).toBe(false)
    expect(isEffortFor('Opencode', 'high#low')).toBe(false)
    expect(effortSchema.safeParse('-high').success).toBe(false)
    expect(effortSchema.safeParse('high#low').success).toBe(false)
    expect(effortSchema.safeParse('xhigh').success).toBe(true)
  })
})
