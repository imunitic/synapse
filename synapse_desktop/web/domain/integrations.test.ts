import { describe, expect, it } from 'vitest'
import type { IntegrationState } from '../../shared/transport.ts'
import {
  HARNESS_NAMES,
  harnessesToConfigure,
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

  const ALL = ['Claude', 'Codex', 'Opencode'] as const
  const states = (claude: IntegrationState, codex = claude, opencode = claude) =>
    ({ Claude: claude, Codex: codex, Opencode: opencode }) as const

  it('offer one button: an install where none has Synapse, a repair where all that need it are broken, else an update', () => {
    expect(installOffer(states('absent'), ALL, '0.18.0')?.label).toBe('Install in all harnesses')
    expect(installOffer(states('broken', 'current'), ALL, '0.18.0')?.label).toBe(
      'Repair in all harnesses',
    )
    expect(installOffer(states('different', 'current', 'absent'), ALL, '0.18.0')?.label).toBe(
      'Update in all harnesses',
    )
  })

  it('offer nothing where every harness is current, or where nothing can be said of it', () => {
    expect(installOffer(states('current', 'installed', 'current'), ALL, '0.18.0')).toBeNull()
    // A harness that is not available does not count, whatever state it is in.
    expect(installOffer(states('different'), [], '0.18.0')).toBeNull()
    expect(installOffer(states('absent', 'current'), ['Codex'], '0.18.0')).toBeNull()
  })

  it("say a newer Synapse is not supported, and offer this app's version in its place", () => {
    const offer = installOffer(states('newer', 'current'), ALL, '0.18.0')
    expect(offer?.label).toBe('Update in all harnesses')
    expect(offer?.command).toBe(installCommand(ALL, '0.18.0'))
    expect(offer?.warning).toContain('Claude Code')
    expect(offer?.warning).toContain('not supported')
    // A development build has no version of its own on npm to offer.
    expect(installOffer(states('newer'), ALL, '0.0.0-dev')).toBeNull()
    expect(installOffer(states('newer'), ALL, null)).toBeNull()
  })

  it("install the npm packages at this app's version, and configure each harness by its own name", () => {
    expect(installCommand(['Claude'], '0.18.0')).toBe(
      'npm install -g @imunitic/synapse@0.18.0 @imunitic/synapse-pipeline@0.18.0 && synapse-setup configure claude && synapse-pipeline-setup configure claude',
    )
    expect(installCommand(['Opencode'], '0.18.0')).toContain('synapse-setup configure opencode')
    expect(installCommand(['Opencode'], '0.18.0')).toContain(
      'synapse-pipeline-setup configure opencode',
    )
  })

  it('install once and configure every available harness, in the same order each time', () => {
    const offer = installOffer(states('different', 'current', 'absent'), ALL, '0.18.0')
    expect(offer?.command.match(/npm install/g)).toHaveLength(1)
    expect(
      offer?.command.endsWith(
        'synapse-setup configure claude && synapse-pipeline-setup configure claude && synapse-setup configure codex && synapse-pipeline-setup configure codex && synapse-setup configure opencode && synapse-pipeline-setup configure opencode',
      ),
    ).toBe(true)
  })

  it('cover the harnesses that are available, and none that is missing', () => {
    expect(harnessesToConfigure(() => false)).toEqual(['Claude', 'Codex', 'Opencode'])
    expect(harnessesToConfigure((h) => h === 'Codex')).toEqual(['Claude', 'Opencode'])
    expect(harnessesToConfigure(() => true)).toEqual([])
  })

  it('install the latest packages from a development build, whose version is not on npm', () => {
    for (const version of ['0.0.0-dev', null]) {
      expect(installCommand(['Claude'], version)).toContain(
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
