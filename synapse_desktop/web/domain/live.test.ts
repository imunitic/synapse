import { describe, expect, it } from 'vitest'
import type { Action, Activity } from './activity.ts'
import type { RunEvent } from './executions.ts'
import { changingCalls, liveSession } from './live.ts'

function event(sequence: number, kind: string, step: string | null, detail: unknown): RunEvent {
  return { sequence, kind, step, detail }
}

const started = (n: number, step: string, attempt = 1, visit = 1): RunEvent =>
  event(n, 'session.started', step, {
    attempt,
    visit,
    transcript: `/w/${visit}-${step}-${attempt}.jsonl`,
    before: 'abc',
  })
const finished = (n: number, step: string): RunEvent =>
  event(n, 'session.finished', step, { attempt: 1, succeeded: true, transcript: null })

const running = { status: 'running', interactive: false } as const

describe('liveSession', () => {
  it('is the session that started and has not finished', () => {
    expect(
      liveSession(
        [event(1, 'step.started', 'Develop', null), started(2, 'Develop', 2, 3)],
        running,
      ),
    ).toEqual({
      step: 'Develop',
      visit: 3,
      attempt: 2,
      transcript: '/w/3-Develop-2.jsonl',
    })
  })

  it('is none once the session finished', () => {
    expect(liveSession([started(1, 'Develop'), finished(2, 'Develop')], running)).toBeNull()
  })

  it('is the second session when the first one finished', () => {
    const live = liveSession(
      [started(1, 'Develop'), finished(2, 'Develop'), started(3, 'Test', 1, 2)],
      running,
    )
    expect(live).toMatchObject({ step: 'Test', visit: 2 })
  })

  it('is none for a run that is not running', () => {
    for (const status of ['completed', 'failed', 'interrupted', 'incomplete'] as const) {
      expect(liveSession([started(1, 'Develop')], { status, interactive: false })).toBeNull()
    }
  })

  it('is none for an interactive run', () => {
    expect(
      liveSession([started(1, 'Develop')], { status: 'running', interactive: true }),
    ).toBeNull()
  })

  it('gives null fields for a detail it cannot read, without throwing', () => {
    for (const detail of [null, 'text', [1], { attempt: 'x', transcript: 7 }]) {
      expect(liveSession([event(1, 'session.started', 'Develop', detail)], running)).toEqual({
        step: 'Develop',
        visit: 0,
        attempt: 0,
        transcript: null,
      })
    }
  })

  it('is none when no session started', () => {
    expect(liveSession([event(1, 'step.started', 'Develop', null)], running)).toBeNull()
  })
})

function activity(...actions: Partial<Action>[]): Activity {
  return {
    harness: 'Claude',
    actions: actions.map((a) => ({
      kind: 'other',
      title: '',
      target: null,
      detail: null,
      status: 'ok',
      ...a,
    })),
    changes: [],
    stats: { costUsd: null, inputTokens: null, outputTokens: null, turns: null, durationMs: null },
  }
}

describe('changingCalls', () => {
  it('counts a finished edit, write and command', () => {
    expect(
      changingCalls(
        activity({ kind: 'edit' }, { kind: 'write' }, { kind: 'command', status: 'failed' }),
      ),
    ).toBe(3)
  })

  it('does not count a pending call, a read or a message', () => {
    expect(
      changingCalls(
        activity({ kind: 'edit', status: 'pending' }, { kind: 'read' }, { kind: 'message' }),
      ),
    ).toBe(0)
  })

  it('goes up when a pending command finishes', () => {
    expect(changingCalls(activity({ kind: 'command', status: 'pending' }))).toBe(0)
    expect(changingCalls(activity({ kind: 'command', status: 'ok' }))).toBe(1)
  })
})
