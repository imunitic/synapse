// The agent run that changes a vault note, kept per note path outside the page, so that the pencil
// and the review's "Send to agent" share one run per note and one result card: a run started by
// either is the one both see, and a second is not started while it is in progress.

import { useEffect, useState } from 'react'
import type { EditNoteRequest, NoteEdit } from '../../shared/transport.ts'
import { transport } from '../transport/index.ts'

export interface NoteEditState {
  // Whether an agent is changing the note now.
  working: boolean
  // What the last run that ended well did to the note, until it is dismissed or another starts.
  edit: NoteEdit | null
  // Why the last run failed, until it is dismissed or another starts.
  failure: string | null
}

const idle: NoteEditState = { working: false, edit: null, failure: null }
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
  set(path, { working: true, edit: null, failure: null })
  transport.editNote(request).then(
    (edit) => {
      set(path, { working: false, edit, failure: null })
      onDone?.(true)
    },
    (error: unknown) => {
      set(path, { working: false, edit: null, failure: String(error).replace(/^Error: /, '') })
      onDone?.(false)
    },
  )
  return true
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
