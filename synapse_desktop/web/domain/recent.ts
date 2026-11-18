// The notes opened in the app lately, kept in the browser so that the home page
// can offer them again after a restart. What the browser keeps is only a
// convenience: when it cannot be read or written there is simply nothing.

const KEY = 'synapse-desktop.recent-notes'
const KEPT = 12

export interface Memory {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
}

function storage(): Memory | null {
  try {
    return globalThis.localStorage
  } catch {
    return null
  }
}

// The paths opened lately, newest first.
export function recentlyOpened(limit: number, memory: Memory | null = storage()): string[] {
  try {
    const parsed: unknown = JSON.parse(memory?.getItem(KEY) ?? '[]')
    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === 'string').slice(0, limit)
      : []
  } catch {
    return []
  }
}

// Notes that a note was opened, ahead of the others and once.
export function recordOpened(path: string, memory: Memory | null = storage()): void {
  if (memory === null) return
  try {
    const next = [path, ...recentlyOpened(KEPT, memory).filter((p) => p !== path)].slice(0, KEPT)
    memory.setItem(KEY, JSON.stringify(next))
  } catch {
    // Nothing is kept, and nothing else is the worse for it.
  }
}
