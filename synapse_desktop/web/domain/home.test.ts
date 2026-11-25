import { describe, expect, it } from 'vitest'
import type { ExecutionSummary } from './executions.ts'
import { recentRuns, runCounts, sessionRows, vaultCounts } from './home.ts'
import type { TerminalSession } from '../state/state.ts'

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
    attention: null,
    interactive: null,
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

describe('the sessions of the running card', () => {
  function session(id: string, kind: TerminalSession['kind'], more: Partial<TerminalSession> = {}) {
    return { id, kind, title: `T ${id}`, cwd: '', ...more } as TerminalSession
  }

  it('lists a shell as a terminal to select', () => {
    expect(sessionRows([session('a', 'Shell')], [])).toEqual([
      { kind: 'terminal', id: 'a', label: 'T a' },
    ])
  })

  it('opens the page of the run for a pipeline session with a run, not the terminals page', () => {
    expect(sessionRows([session('p', 'Pipeline', { executionId: 'exec-1' })], [])).toEqual([
      { kind: 'run', id: 'p', label: 'T p', page: { kind: 'execution', id: 'exec-1' } },
    ])
  })

  it('opens the starting page for a pipeline session whose run has no id yet', () => {
    expect(sessionRows([session('p', 'Pipeline')], [])).toEqual([
      { kind: 'run', id: 'p', label: 'T p', page: { kind: 'run-starting', session: 'p' } },
    ])
  })

  it('does not list a run twice when the card already lists it as running', () => {
    const listed = run('exec-1', 'running', '2026-11-08T11:00:00Z')
    expect(sessionRows([session('p', 'Pipeline', { executionId: 'exec-1' })], [listed])).toEqual([])
  })
})
