import { describe, expect, it } from 'vitest'
import type { ExecutionSummary } from './executions.ts'
import {
  clampIndex,
  closeWarning,
  firstMovableIndex,
  indexAfterMove,
  insertionAt,
  insertionPoint,
} from './tabs.ts'
import type { TerminalSession } from '../state/state.ts'

describe('where a dragged tab lands', () => {
  it('is before the tab hovered over in its left half, and after it in its right half', () => {
    expect(insertionPoint(2, 0.2)).toBe(2)
    expect(insertionPoint(2, 0.5)).toBe(3)
    expect(insertionPoint(2, 0.9)).toBe(3)
  })

  it('is an index of the list without the tab that was taken out', () => {
    // [a b c d]: c taken out, then put before a, before b, where it was, and at the end.
    expect(indexAfterMove(2, 0)).toBe(0)
    expect(indexAfterMove(2, 1)).toBe(1)
    expect(indexAfterMove(2, 2)).toBe(2)
    expect(indexAfterMove(2, 3)).toBe(2)
    expect(indexAfterMove(2, 4)).toBe(3)
    // a taken out, then put after b.
    expect(indexAfterMove(0, 2)).toBe(1)
  })

  it('is found from where the tabs are on the screen and where the pointer is', () => {
    // Three tabs 100 wide with a 2 gap: Home at 0, then 102 and 204.
    const spans = [
      { left: 0, width: 100 },
      { left: 102, width: 100 },
      { left: 204, width: 100 },
    ]
    expect(insertionAt(spans, 110, 1)).toBe(1)
    expect(insertionAt(spans, 190, 1)).toBe(2)
    // In the gap before a tab is before it.
    expect(insertionAt(spans, 203, 1)).toBe(2)
    // Past the last tab is after it.
    expect(insertionAt(spans, 900, 1)).toBe(3)
    // Over Home, or before it, is after Home, which stays first.
    expect(insertionAt(spans, 10, 1)).toBe(1)
    expect(insertionAt(spans, -50, 1)).toBe(1)
    expect(insertionAt([], 10, 0)).toBe(0)
  })

  it('is never before the Home tab, which is first', () => {
    expect(firstMovableIndex(['home', 'a', 'b'])).toBe(1)
    expect(firstMovableIndex(['a', 'b'])).toBe(0)
    expect(clampIndex(0, ['home', 'a', 'b'])).toBe(1)
    expect(clampIndex(9, ['home', 'a', 'b'])).toBe(2)
    expect(clampIndex(0, ['a', 'b'])).toBe(0)
  })
})

const session = (id: string, ended?: boolean): TerminalSession => ({
  id,
  kind: 'Shell',
  title: id,
  cwd: '',
  ...(ended === undefined ? {} : { ended }),
})

function run(id: string, status: ExecutionSummary['status']): ExecutionSummary {
  return {
    id,
    pipeline: 'P',
    status,
    started: null,
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

describe('what closing a tab asks about', () => {
  it('is the sessions of the terminals page whose program is still running', () => {
    const page = { kind: 'terminals' } as const
    expect(closeWarning(page, [session('a')], [])).toBe(
      'One session is still running, and closing the tab ends it.',
    )
    expect(closeWarning(page, [session('a'), session('b'), session('c', true)], [])).toBe(
      '2 sessions are still running, and closing the tab ends them.',
    )
  })

  it('says that an interactive run goes on, beside the sessions the page ends', () => {
    const page = { kind: 'terminals' } as const
    const interactive = (id: string, ended?: boolean): TerminalSession => ({
      ...session(id, ended),
      kind: 'Pipeline',
    })
    expect(closeWarning(page, [interactive('r')], [])).toBe(
      'An interactive run is going on, and closing the tab does not stop it.',
    )
    expect(closeWarning(page, [session('a'), interactive('r')], [])).toBe(
      'One session is still running, and closing the tab ends it. An interactive run is going on, and closing the tab does not stop it.',
    )
    expect(closeWarning(page, [interactive('r', true)], [])).toBeNull()
  })

  it('is nothing for the terminals page when every session has ended', () => {
    expect(closeWarning({ kind: 'terminals' }, [session('a', true)], [])).toBeNull()
    expect(closeWarning({ kind: 'terminals' }, [], [])).toBeNull()
  })

  it('is a run that is going on, which closing the tab does not stop', () => {
    const page = { kind: 'execution', id: 'r1' } as const
    expect(closeWarning(page, [], [run('r1', 'running')])).toBe(
      'This run is still going. Closing the tab does not stop it.',
    )
    expect(closeWarning(page, [], [run('r1', 'completed')])).toBeNull()
    expect(closeWarning(page, [], [run('other', 'running')])).toBeNull()
    expect(closeWarning(page, [], [])).toBeNull()
  })

  it('says that closing the page of a run that is starting ends the run', () => {
    const run: TerminalSession = { ...session('r'), kind: 'Pipeline' }
    const page = { kind: 'run-starting', session: 'r' } as const
    expect(closeWarning(page, [run], [])).toMatch(/stops it/)
    expect(closeWarning(page, [{ ...run, ended: true }], [])).toBeNull()
    expect(closeWarning(page, [], [])).toBeNull()
  })

  it('is nothing for any other page', () => {
    expect(closeWarning({ kind: 'home' }, [session('a')], [run('r1', 'running')])).toBeNull()
    expect(closeWarning({ kind: 'graph' }, [], [])).toBeNull()
    expect(closeWarning({ kind: 'launch' }, [session('a')], [])).toBeNull()
  })
})
