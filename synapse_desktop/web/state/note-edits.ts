// The agent run that changes a vault note, kept per note path outside the page, so that the pencil
// and the review's "Send to agent" share one run per note and one result card: a run started by
// either is the one both see, and a second is not started while it is in progress.

import { useEffect, useState } from 'react'
import type { EditNoteRequest, Harness, NoteEdit } from '../../shared/transport.ts'
import { transport } from '../transport/index.ts'

export interface NoteEditState {
  // Whether an agent is changing the note now.
  working: boolean
  // What the last run that ended well did to the note, until it is dismissed or another starts.
  edit: NoteEdit | null
  // Why the last run failed, until it is dismissed or another starts.
  failure: string | null
  // The run in progress: its id, when it started (ms since the epoch), the harness it runs with,
  // whether a stop was asked for, and the stream lines it has published so far. Empty when idle.
  run: string | null
  startedAt: number | null
  harness: Harness | null
  stopping: boolean
  lines: readonly string[]
}

const noRun = { run: null, startedAt: null, harness: null, stopping: false, lines: [] } as const
const idle: NoteEditState = { working: false, edit: null, failure: null, ...noRun }
const states = new Map<string, NoteEditState>()
const listeners = new Set<() => void>()

function set(path: string, state: NoteEditState): void {
  if (!state.working && state.edit === null && state.failure === null) states.delete(path)
  else states.set(path, state)
  for (const listener of listeners) listener()
}

export function noteEditOf(path: string): NoteEditState {
  return states.get(path) ?? idle
}

// Starts an agent run on the note; false, and nothing started, while one on it is in progress.
// `onDone` is told whether the run changed the note, once it has ended.
export function startNoteEdit(
  path: string,
  request: EditNoteRequest,
  onDone?: (ok: boolean) => void,
): boolean {
  if (noteEditOf(path).working) return false
  const run = crypto.randomUUID()
  set(path, {
    working: true,
    edit: null,
    failure: null,
    run,
    startedAt: Date.now(),
    harness: request.harness ?? null,
    stopping: false,
    lines: [],
  })
  // Watched before the request is sent, so no line is missed.
  const unwatch = transport.watchNoteRun(run, (line) => {
    const state = noteEditOf(path)
    if (state.run === run) set(path, { ...state, lines: [...state.lines, line] })
  })
  transport.editNote({ ...request, run }).then(
    (edit) => {
      unwatch()
      set(path, { ...idle, edit })
      onDone?.(true)
    },
    (error: unknown) => {
      unwatch()
      set(path, { ...idle, failure: String(error).replace(/^Error: /, '') })
      onDone?.(false)
    },
  )
  return true
}

// Asks the host to end the note's run in progress. The run then ends through the edit's own
// result or failure, as any run does.
export function stopNoteEdit(path: string): void {
  const state = noteEditOf(path)
  if (!state.working || state.run === null || state.stopping) return
  set(path, { ...state, stopping: true })
  transport.stopAgentRun(state.run).catch(() => {})
}

// Forgets the result or the failure of the note's last run; a run in progress is kept.
export function dismissNoteEdit(path: string): void {
  const state = noteEditOf(path)
  if (state.working) return
  set(path, idle)
}

// Told when the run of any note starts or ends; the way to stop is what this returns.
export function onNoteEditChange(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

// The run of a note, read again whenever one starts or ends.
export function useNoteEdit(path: string): NoteEditState {
  const [, setTick] = useState(0)
  useEffect(() => onNoteEditChange(() => setTick((n) => n + 1)), [])
  return noteEditOf(path)
}
