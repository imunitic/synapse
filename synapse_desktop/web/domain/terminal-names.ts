// The names a person gave terminal sessions, kept in the browser by session id so that a page
// that is reloaded shows them again. A session's id lasts as long as the host keeps the session,
// so the name goes with it; it is forgotten when the session is closed. When the browser keeps
// nothing, a session shows its title.

import type { Memory } from './recent.ts'

const KEY = 'synapse-desktop.terminal-names'
// A bound on what is kept for sessions that ended without being closed: the oldest goes first.
const KEPT = 200

function storage(): Memory | null {
  try {
    return globalThis.localStorage
  } catch {
    return null
  }
}

function stored(memory: Memory | null): [string, string][] {
  try {
    const parsed: unknown = JSON.parse(memory?.getItem(KEY) ?? '[]')
    return Array.isArray(parsed)
      ? parsed.filter(
          (pair): pair is [string, string] =>
            Array.isArray(pair) &&
            pair.length === 2 &&
            typeof pair[0] === 'string' &&
            typeof pair[1] === 'string',
        )
      : []
  } catch {
    return []
  }
}

export function storedName(session: string, memory: Memory | null = storage()): string | null {
  return stored(memory).find(([id]) => id === session)?.[1] ?? null
}

// Keeps a name for the session, or forgets it when the name is null or blank.
export function storeName(
  session: string,
  name: string | null,
  memory: Memory | null = storage(),
): void {
  if (memory === null) return
  const others = stored(memory).filter(([id]) => id !== session)
  const trimmed = name?.trim() ?? ''
  const next: [string, string][] =
    trimmed === '' ? others : [[session, trimmed] as [string, string], ...others].slice(0, KEPT)
  try {
    memory.setItem(KEY, JSON.stringify(next))
  } catch {
    // The name holds until the page is reloaded.
  }
}
