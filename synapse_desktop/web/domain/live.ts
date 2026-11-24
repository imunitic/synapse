// The step of a run that is going on right now: which session is open, from the events, and how
// much of what it has done can have changed files.

import type { Activity } from './activity.ts'
import type { ExecutionSummary, RunEvent } from './executions.ts'

export interface LiveSession {
  step: string
  visit: number
  attempt: number
  // Where the runner writes the transcript, or null when the event does not say.
  transcript: string | null
}

function field(detail: unknown, key: string): unknown {
  return typeof detail === 'object' && detail !== null && !Array.isArray(detail)
    ? (detail as Record<string, unknown>)[key]
    : undefined
}

function count(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

// The session that has started and not finished, for a run that is running and has no terminal.
// A `session.started` with a detail that cannot be read still counts, with empty fields.
export function liveSession(
  events: readonly RunEvent[],
  summary: Pick<ExecutionSummary, 'status' | 'interactive'>,
): LiveSession | null {
  if (summary.status !== 'running' || summary.interactive === true) return null
  const started = events.findLastIndex((e) => e.kind === 'session.started' && e.step !== null)
  if (started < 0) return null
  const event = events[started]
  if (event?.step == null) return null
  const finished = events
    .slice(started + 1)
    .some((e) => e.kind === 'session.finished' && e.step === event.step)
  if (finished) return null
  const transcript = field(event.detail, 'transcript')
  return {
    step: event.step,
    visit: count(field(event.detail, 'visit')),
    attempt: count(field(event.detail, 'attempt')),
    transcript: typeof transcript === 'string' && transcript !== '' ? transcript : null,
  }
}

// How many actions of a kind that can change files have finished: the number goes up each time
// one does, which is when the changes are worth asking for.
export function changingCalls(activity: Activity): number {
  return activity.actions.filter(
    (a) =>
      (a.kind === 'edit' || a.kind === 'write' || a.kind === 'command') && a.status !== 'pending',
  ).length
}
