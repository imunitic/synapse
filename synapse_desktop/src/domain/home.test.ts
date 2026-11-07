import { describe, expect, it } from 'vitest'
import type { AppConfig, Integration } from '../../shared/transport.ts'
import type { VaultAttention } from './attention.ts'
import type { ExecutionSummary } from './executions.ts'
import { recentRuns, runCounts, setupSteps, vaultCounts } from './home.ts'

const NOW = new Date('2026-11-08T12:00:00Z')

function run(
  id: string,
  status: ExecutionSummary['status'],
  started: string | null,
): ExecutionSummary {
  return {
    id,
    pipeline: 'P',
    status,
    started,
    ended: null,
    currentStep: null,
    stepsRun: null,
    failure: null,
    failureStep: null,
    fired: [],
  }
}

describe('run counts', () => {
  it('count how the runs of the last week ended, and the ones going', () => {
    const counts = runCounts(
      [
        run('a', 'completed', '2026-11-07T10:00:00Z'),
        run('b', 'completed', '2026-11-06T10:00:00Z'),
        run('c', 'failed', '2026-11-05T10:00:00Z'),
        run('d', 'interrupted', '2026-11-08T08:00:00Z'),
        run('e', 'running', '2026-11-08T11:00:00Z'),
        run('f', 'completed', '2026-10-01T10:00:00Z'),
        run('g', 'incomplete', null),
        run('h', 'completed', 'not a date'),
      ],
      NOW,
    )
    expect(counts).toEqual({ running: 1, completed: 2, failed: 1, interrupted: 1 })
  })

  it('are all zero with no runs', () => {
    expect(runCounts([], NOW)).toEqual({ running: 0, completed: 0, failed: 0, interrupted: 0 })
  })
})

describe('recent runs', () => {
  it('are the first ones that have a start, as many as asked for', () => {
    const runs = [
      run('a', 'completed', '2026-11-08T10:00:00Z'),
      run('b', 'incomplete', null),
      run('c', 'failed', '2026-11-07T10:00:00Z'),
      run('d', 'completed', '2026-11-06T10:00:00Z'),
    ]
    expect(recentRuns(runs, 2).map((r) => r.id)).toEqual(['a', 'c'])
  })
})

const config = (workDir: string | null) =>
  ({
    status: 'ready',
    data: {
      workDir,
      definitionPaths: [],
      defaultHarness: null,
      env: {},
      recentVaults: [],
      terminalFolder: null,
    } satisfies AppConfig,
  }) as const

const vault = (configured: boolean) =>
  ({
    status: 'ready',
    data: (configured
      ? { configured: true, vault: '/v', categories: [] }
      : { configured: false }) satisfies VaultAttention,
  }) as const

const harnesses = (...states: Integration['state'][]) =>
  ({
    status: 'ready',
    data: states.map((state, i) => ({
      harness: (['Claude', 'Codex', 'Opencode'] as const)[i] ?? 'Claude',
      state,
      hook: null,
      version: null,
    })),
  }) as const

describe('setup steps', () => {
  it('say what is done and what is not, each leading to the page that does it', () => {
    const steps = setupSteps({
      config: config(null),
      vault: vault(false),
      integrations: harnesses('absent', 'absent', 'absent'),
    })
    expect(steps.map((s) => [s.key, s.done])).toEqual([
      ['work-dir', false],
      ['vault', false],
      ['harness', false],
    ])
    expect(steps.map((s) => s.target.section)).toEqual(['general', 'vault', 'integrations'])
  })

  it('are done when a work directory, a vault and a working install are there', () => {
    const steps = setupSteps({
      config: config('/w'),
      vault: vault(true),
      integrations: harnesses('absent', 'newer'),
    })
    expect(steps.every((s) => s.done)).toBe(true)
  })

  it('count an install whose hook program is gone as not done', () => {
    const steps = setupSteps({
      config: config('/w'),
      vault: vault(true),
      integrations: harnesses('broken'),
    })
    expect(steps.find((s) => s.key === 'harness')?.done).toBe(false)
  })

  it('leave out a step whose answer is not known yet, or could not be read', () => {
    const steps = setupSteps({
      config: config('/w'),
      vault: { status: 'loading' },
      integrations: { status: 'failed', error: 'x' },
    })
    expect(steps.map((s) => s.key)).toEqual(['work-dir'])
  })
})

describe('vault counts', () => {
  it('are the number of items by category', () => {
    expect(
      vaultCounts([
        { key: 'discussing', title: 'D', items: [{ path: 'a', id: null, title: 'A' }] },
        { key: 'in_progress', title: 'I', items: [] },
      ]),
    ).toEqual({ discussing: 1, in_progress: 0 })
  })
})
