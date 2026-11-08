import { describe, expect, it } from 'vitest'
import type { Diagnosis, DoctorFinding } from '../../shared/transport.ts'
import {
  attentionOf,
  dismissedWarnings,
  effectiveHarness,
  harnessAvailability,
  HARNESS_INSTALLS,
} from './diagnosis.ts'

const finding = (
  key: string,
  status: DoctorFinding['status'],
  detail = '',
  value = '',
): DoctorFinding => ({ key, name: key, status, detail, value })

const diagnosis = (...findings: DoctorFinding[]): Diagnosis => ({
  findings,
  counts: {
    ok: findings.filter((f) => f.status === 'ok').length,
    warn: findings.filter((f) => f.status === 'warn').length,
    fail: findings.filter((f) => f.status === 'fail').length,
  },
})

const NONE = new Set<string>()

describe('harnessAvailability', () => {
  it('is installed where the check found the program, and missing where it did not', () => {
    const found = harnessAvailability(
      diagnosis(
        finding('claude', 'ok', '2.1, Synapse installed', '/bin/claude'),
        finding('codex', 'ok', 'not installed'),
        finding('opencode', 'warn', '2.2, Synapse is not installed', '/bin/opencode'),
      ),
    )
    expect(found).toEqual({ Claude: 'installed', Codex: 'missing', Opencode: 'installed' })
  })

  it('is not known without a diagnosis, and for a harness the check did not name', () => {
    expect(harnessAvailability(null)).toEqual({
      Claude: 'unknown',
      Codex: 'unknown',
      Opencode: 'unknown',
    })
    expect(harnessAvailability(diagnosis(finding('git', 'ok')))).toEqual({
      Claude: 'unknown',
      Codex: 'unknown',
      Opencode: 'unknown',
    })
  })
})

describe('effectiveHarness', () => {
  const only = (h: 'Claude' | 'Codex' | 'Opencode') =>
    harnessAvailability(
      diagnosis(
        finding('claude', 'ok', '', h === 'Claude' ? '/c' : ''),
        finding('codex', 'ok', '', h === 'Codex' ? '/x' : ''),
        finding('opencode', 'ok', '', h === 'Opencode' ? '/o' : ''),
      ),
    )

  it('is the one that was chosen while it is there', () => {
    expect(effectiveHarness('Codex', only('Codex'))).toBe('Codex')
  })

  it('is the first that is there when the one chosen is missing, or none was chosen', () => {
    expect(effectiveHarness('Claude', only('Opencode'))).toBe('Opencode')
    expect(effectiveHarness(null, only('Codex'))).toBe('Codex')
  })

  it('is the one chosen, or Claude Code, when nothing can be said', () => {
    expect(effectiveHarness('Codex', harnessAvailability(null))).toBe('Codex')
    expect(effectiveHarness(null, harnessAvailability(null))).toBe('Claude')
    // None is there: what was chosen, so that the page that fails says which one.
    const none = harnessAvailability(
      diagnosis(finding('claude', 'ok'), finding('codex', 'ok'), finding('opencode', 'ok')),
    )
    expect(effectiveHarness('Codex', none)).toBe('Codex')
    expect(effectiveHarness(null, none)).toBe('Claude')
  })
})

describe('attentionOf', () => {
  it('is nothing when everything is fine', () => {
    expect(attentionOf(diagnosis(finding('git', 'ok'), finding('vault', 'ok')), NONE)).toEqual([])
  })

  it('puts errors before warnings, each in the order found', () => {
    const found = attentionOf(
      diagnosis(
        finding('pipeline', 'warn', 'not on PATH'),
        finding('vault', 'fail', 'not set'),
        finding('vault-index', 'warn', 'no Index.md'),
        finding('config', 'fail', 'no synapse.conf'),
      ),
      NONE,
    )
    expect(found.map((a) => `${a.severity}:${a.key}`)).toEqual([
      'error:vault',
      'warning:pipeline',
      'warning:vault-index',
    ])
  })

  it('says nothing of one harness that is missing, and fails when there is none', () => {
    const some = attentionOf(
      diagnosis(
        finding('claude', 'ok', 'installed', '/c'),
        finding('codex', 'ok', 'not installed'),
      ),
      NONE,
    )
    expect(some).toEqual([])
    const none = attentionOf(
      diagnosis(
        finding('claude', 'warn', 'not installed'),
        finding('codex', 'warn', 'not installed'),
        finding('opencode', 'warn', 'not installed'),
        finding('harness', 'fail', 'none of them is installed'),
      ),
      NONE,
    )
    expect(none.map((a) => a.key)).toEqual(['harness'])
    expect(none[0]?.fixes).toEqual(
      ['Claude', 'Codex', 'Opencode'].map((h) => ({
        kind: 'command',
        label: HARNESS_INSTALLS[h as 'Claude'].label,
        command: HARNESS_INSTALLS[h as 'Claude'].command,
      })),
    )
  })

  it('points a harness without Synapse, and the hooks, at the page that installs it', () => {
    const found = attentionOf(
      diagnosis(
        finding('claude', 'warn', '2.1, Synapse is not installed in it', '/c'),
        finding('hooks', 'fail', 'none of the harnesses has it'),
      ),
      NONE,
    )
    for (const item of found) {
      expect(item.fixes).toEqual([
        { kind: 'settings', section: 'integrations', label: 'Install Synapse in a harness' },
      ])
    }
  })

  it('points the vault, and the vault index, at the vault settings', () => {
    const found = attentionOf(
      diagnosis(finding('vault', 'fail', 'not set'), finding('vault-index', 'warn', 'no Index.md')),
      NONE,
    )
    expect(found.map((a) => a.fixes[0])).toEqual([
      { kind: 'settings', section: 'vault', label: 'Choose a vault' },
      { kind: 'settings', section: 'vault', label: 'Open the vault settings' },
    ])
  })

  it('says the configuration only when the vault is not what is missing', () => {
    const both = attentionOf(
      diagnosis(finding('config', 'fail', 'no synapse.conf'), finding('vault', 'fail', 'not set')),
      NONE,
    )
    expect(both.map((a) => a.key)).toEqual(['vault'])
    const alone = attentionOf(
      diagnosis(finding('config', 'fail', 'no synapse.conf'), finding('vault', 'ok', '/v', '/v')),
      NONE,
    )
    expect(alone.map((a) => a.key)).toEqual(['config'])
    expect(alone[0]?.fixes).toEqual([
      { kind: 'settings', section: 'vault', label: 'Choose a vault' },
    ])
  })

  it('gives synapse-pipeline a command to install it, and git none', () => {
    const [pipeline, git] = attentionOf(
      diagnosis(finding('pipeline', 'warn', 'not on PATH'), finding('git', 'fail', 'not on PATH')),
      NONE,
    )
      .sort((a, b) => a.key.localeCompare(b.key))
      .reverse()
    expect(pipeline?.fixes).toEqual([
      {
        kind: 'command',
        label: 'synapse-pipeline',
        command: 'npm install -g @imunitic/synapse-pipeline',
      },
    ])
    expect(git?.fixes).toEqual([])
  })

  it('leaves out a warning that was put aside, and never an error', () => {
    const d = diagnosis(finding('pipeline', 'warn', 'x'), finding('vault', 'fail', 'y'))
    const found = attentionOf(d, new Set(['pipeline', 'vault']))
    expect(found.map((a) => a.key)).toEqual(['vault'])
    expect(found[0]?.dismissible).toBe(false)
    expect(attentionOf(d, NONE).find((a) => a.key === 'pipeline')?.dismissible).toBe(true)
  })

  it('names what a check is for a person, and falls back to its own name', () => {
    const [a, b] = attentionOf(
      diagnosis(finding('opencode', 'warn', 'x', '/o'), {
        ...finding('odd', 'warn'),
        name: 'odd thing',
      }),
      NONE,
    )
    expect(a?.title).toBe('OpenCode')
    expect(b?.title).toBe('odd thing')
  })
})

describe('dismissedWarnings', () => {
  it('lists the warnings put aside that are still found', () => {
    const d = diagnosis(finding('pipeline', 'warn'), finding('vault', 'fail'), finding('git', 'ok'))
    expect(dismissedWarnings(d, new Set(['pipeline', 'vault', 'git', 'gone']))).toEqual([
      'pipeline',
    ])
    expect(dismissedWarnings(d, NONE)).toEqual([])
  })
})
