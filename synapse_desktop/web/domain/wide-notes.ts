// The notes shown at the full width of the page, each chosen on its own note and
// kept in the browser. It is a convenience of the person reading, so the note
// itself is not written; when the browser keeps nothing, every note is narrow.

import type { Memory } from './recent.ts'

const KEY = 'synapse-desktop.wide-notes'
// Enough for every note anyone widens, and a bound on what is kept for notes
// that were since renamed or deleted: the oldest choice is forgotten first.
const KEPT = 500

function storage(): Memory | null {
  try {
    return globalThis.localStorage
  } catch {
    return null
  }
}

function widened(memory: Memory | null): string[] {
  try {
    const parsed: unknown = JSON.parse(memory?.getItem(KEY) ?? '[]')
    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === 'string')
      : []
  } catch {
    return []
  }
}

export function isWide(path: string, memory: Memory | null = storage()): boolean {
  return widened(memory).includes(path)
}

export function setWide(path: string, wide: boolean, memory: Memory | null = storage()): void {
  if (memory === null) return
  const others = widened(memory).filter((p) => p !== path)
  const next = wide ? [path, ...others].slice(0, KEPT) : others
  try {
    memory.setItem(KEY, JSON.stringify(next))
  } catch {
    // The note stays as it was, and nothing else is the worse for it.
  }
}
