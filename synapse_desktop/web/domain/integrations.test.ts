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
    expect(installOffer('Claude', 'absent', '0.18.0')?.label).toBe('Install')
    expect(installOffer('Claude', 'broken', '0.18.0')?.label).toBe('Repair')
    expect(installOffer('Claude', 'different', '0.18.0')?.label).toBe('Update')
  })

  it('offer nothing where it is current, or where nothing can be said of it', () => {
    for (const state of ['current', 'installed'] as const) {
      expect(installOffer('Codex', state, '0.18.0')).toBeNull()
    }
  })

  it("say a newer Synapse is not supported, and offer this app's version in its place", () => {
    const offer = installOffer('Claude', 'newer', '0.18.0')
    expect(offer?.label).toBe('Install 0.18.0')
    expect(offer?.command).toBe(installCommand('Claude', '0.18.0'))
    expect(offer?.warning).toContain('not supported')
    // A development build has no version of its own on npm to offer.
    expect(installOffer('Claude', 'newer', '0.0.0-dev')).toBeNull()
    expect(installOffer('Claude', 'newer', null)).toBeNull()
  })

  it("install the npm packages at this app's version, and configure each harness by its own name", () => {
    expect(installCommand('Claude', '0.18.0')).toBe(
      'npm install -g @imunitic/synapse@0.18.0 @imunitic/synapse-pipeline@0.18.0 && synapse-setup configure claude && synapse-pipeline-setup configure claude',
    )
    expect(installCommand('Opencode', '0.18.0')).toContain('synapse-setup configure opencode')
    expect(installCommand('Opencode', '0.18.0')).toContain(
      'synapse-pipeline-setup configure opencode',
    )
    expect(installOffer('Codex', 'absent', '0.18.0')?.command).toBe(
      installCommand('Codex', '0.18.0'),
    )
  })

  it('install the latest packages from a development build, whose version is not on npm', () => {
    for (const version of ['0.0.0-dev', null]) {
      expect(installCommand('Claude', version)).toContain(
        '@imunitic/synapse@latest @imunitic/synapse-pipeline@latest',
      )
    }
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
