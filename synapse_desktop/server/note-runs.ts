// The runs of an agent on a note, a new note or a definition, which a client can watch and stop. A
// run is known by the id the client made for it. It keeps the lines the agent printed, so a client
// that subscribes late, or again after a drop, reads them from its cursor.

import { HostError } from '../shared/dispatch.ts'
import type { Cursor } from '../shared/protocol.ts'

type Push = (data: unknown, cursor?: Cursor) => void

// How long a finished run stays readable, for a subscriber that comes after it ended.
const KEEP_MS = 60_000

export interface NoteRunHandle {
  signal: AbortSignal
  publish(line: string): void
  finish(): void
  stopped(): boolean
}

export interface NoteRuns {
  start(id: string): NoteRunHandle
  stop(id: string): void
  subscribe(id: string, after: Cursor | undefined, push: Push): () => void
}

interface Subscriber {
  // The index of the next line this subscriber has not been given.
  next: number
  push: Push
}

interface Entry {
  controller: AbortController
  lines: string[]
  subscribers: Set<Subscriber>
  stopped: boolean
  finished: boolean
}

export function createNoteRuns(): NoteRuns {
  const entries = new Map<string, Entry>()
  // Subscribers of an id that has not started: a client watches before it sends the request.
  const waiting = new Map<string, Set<Subscriber>>()

  function deliver(entry: Entry, subscriber: Subscriber): void {
    while (subscriber.next < entry.lines.length) {
      const index = subscriber.next
      subscriber.next += 1
      subscriber.push({ line: entry.lines[index] }, index)
    }
  }

  return {
    start(id) {
      if (entries.get(id)?.finished === false) {
        throw new HostError('conflict', `the run ${id} is already running`)
      }
      const entry: Entry = {
        controller: new AbortController(),
        lines: [],
        subscribers: waiting.get(id) ?? new Set(),
        stopped: false,
        finished: false,
      }
      waiting.delete(id)
      entries.set(id, entry)
      return {
        signal: entry.controller.signal,
        publish(line) {
          entry.lines.push(line)
          for (const subscriber of entry.subscribers) deliver(entry, subscriber)
        },
        finish() {
          if (entry.finished) return
          entry.finished = true
          const timer = setTimeout(() => {
            if (entries.get(id) === entry) entries.delete(id)
          }, KEEP_MS)
          timer.unref()
        },
        stopped: () => entry.stopped,
      }
    },

    stop(id) {
      const entry = entries.get(id)
      if (entry === undefined || entry.finished) return
      entry.stopped = true
      entry.controller.abort()
    },

    subscribe(id, after, push) {
      const subscriber: Subscriber = { next: after === undefined ? 0 : after + 1, push }
      const entry = entries.get(id)
      if (entry === undefined) {
        const set = waiting.get(id) ?? new Set()
        set.add(subscriber)
        waiting.set(id, set)
      } else {
        entry.subscribers.add(subscriber)
        deliver(entry, subscriber)
      }
      return () => {
        waiting.get(id)?.delete(subscriber)
        entries.get(id)?.subscribers.delete(subscriber)
      }
    },
  }
}
