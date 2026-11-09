import { describe, expect, it } from 'vitest'
import type { IntegrationState } from '../../shared/transport.ts'
import {
  HARNESS_NAMES,
  installCommand,
  installOffer,
  stateLabel,
  writesFor,
} from './integrations.ts'

const STATES: IntegrationState[] = [
  'absent',
  'current',
  'different',
  'broken',
  'installed',
  'newer',
]

describe('integrations', () => {
  it('say each state in words', () => {
    expect(stateLabel('absent')).toBe('Not installed')
    expect(stateLabel('current')).toBe('Installed, up to date')
    expect(stateLabel('broken')).toBe('Its hook program is missing')
  })

  it('never say two states the same way, or leave one without words', () => {
    expect(new Set(STATES.map(stateLabel)).size).toBe(STATES.length)
    for (const state of STATES) expect(stateLabel(state)).not.toBe('')
  })

  it('offer an install, a repair or an update where Synapse is missing, broken or another copy', () => {
    expect(installOffer('Claude', 'absent')?.label).toBe('Install')
    expect(installOffer('Claude', 'broken')?.label).toBe('Repair')
    expect(installOffer('Claude', 'different')?.label).toBe('Update')
  })

  it('offer nothing where it is current or newer, or where nothing can be said of it', () => {
    for (const state of ['current', 'newer', 'installed'] as const) {
      expect(installOffer('Codex', state)).toBeNull()
    }
  })

  it('install from npm and configure each harness by its own name', () => {
    expect(installCommand('Claude')).toBe(
      'npm install -g @imunitic/synapse@latest @imunitic/synapse-pipeline@latest && synapse-setup configure claude && synapse-pipeline-setup configure claude',
    )
    expect(installCommand('Opencode')).toContain('synapse-setup configure opencode')
    expect(installCommand('Opencode')).toContain('synapse-pipeline-setup configure opencode')
    expect(installOffer('Codex', 'absent')?.command).toBe(installCommand('Codex'))
  })

  it('say which files of a harness installing writes, and keep a copy of the ones it merges into', () => {
    expect(writesFor('Claude').join(' ')).toContain('settings.json.bak')
    expect(writesFor('Codex').join(' ')).toContain('hooks.json.bak')
    expect(writesFor('Opencode').join(' ')).toContain('plugin/synapse.js')
    for (const harness of ['Claude', 'Codex', 'Opencode'] as const) {
      expect(writesFor(harness).length).toBeGreaterThan(0)
    }
  })

  it('name the three harnesses as people do', () => {
    expect(Object.values(HARNESS_NAMES)).toEqual(['Claude Code', 'Codex', 'OpenCode'])
  })
})
