import { describe, expect, it } from 'vitest'
import type { IntegrationState } from '../../shared/transport.ts'
import { actionLabel, HARNESS_NAMES, stateLabel } from './integrations.ts'

const STATES: IntegrationState[] = ['absent', 'current', 'different', 'broken', 'installed']

describe('integrations', () => {
  it('say each state in words, with a button that fits it', () => {
    expect(stateLabel('absent')).toBe('Not installed')
    expect(actionLabel('absent')).toBe('Install')
    expect(actionLabel('different')).toBe('Update')
    expect(actionLabel('broken')).toBe('Repair')
    expect(actionLabel('current')).toBe('Reinstall')
  })

  it('never say two states the same way, or leave one without words', () => {
    expect(new Set(STATES.map(stateLabel)).size).toBe(STATES.length)
    for (const state of STATES) {
      expect(stateLabel(state)).not.toBe('')
      expect(actionLabel(state)).not.toBe('')
    }
  })

  it('name the three harnesses as people do', () => {
    expect(Object.values(HARNESS_NAMES)).toEqual(['Claude Code', 'Codex', 'OpenCode'])
  })
})
