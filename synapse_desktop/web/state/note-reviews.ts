// The review each vault note has in progress: the comments written on its sections or on the whole
// note, kept for the life of the tab until they are sent to the agent or discarded, so that a page
// loaded again still has them. Nothing here is written to the vault.

import { useEffect, useState } from 'react'
import type { NoteComment } from '../domain/note-review.ts'

const KEY = 'synapse-desktop.note-reviews'

function readAll(): Record<string, NoteComment[]> {
  try {
    const raw = sessionStorage.getItem(KEY)
    const parsed: unknown = raw === null ? {} : JSON.parse(raw)
    return typeof parsed === 'object' && parsed !== null
      ? (parsed as Record<string, NoteComment[]>)
      : {}
  } catch {
    return {}
  }
}

// Kept for the session of the browser; storage may be missing or full, and then it is kept here.
const kept = new Map<string, NoteComment[]>()
const listeners = new Set<() => void>()
let counter = 0

export function noteReviewOf(path: string): NoteComment[] {
  return kept.get(path) ?? readAll()[path] ?? []
}

function keep(path: string, comments: NoteComment[]): void {
  if (comments.length === 0) kept.delete(path)
  else kept.set(path, comments)
  try {
    const all = readAll()
    if (comments.length === 0) delete all[path]
    else all[path] = comments
    sessionStorage.setItem(KEY, JSON.stringify(all))
  } catch {
    // Not kept beyond this page.
  }
  for (const listener of listeners) listener()
}

export function addNoteComment(path: string, comment: Omit<NoteComment, 'id'>): void {
  counter += 1
  keep(path, [...noteReviewOf(path), { ...comment, id: `${Date.now()}-${counter}` }])
}

export function editNoteComment(path: string, id: string, text: string): void {
  keep(
    path,
    noteReviewOf(path).map((c) => (c.id === id ? { ...c, text } : c)),
  )
}

export function removeNoteComment(path: string, id: string): void {
  keep(
    path,
    noteReviewOf(path).filter((c) => c.id !== id),
  )
}

// Removes the comments with these ids and keeps the rest, such as those written while a review
// was being sent.
export function removeNoteComments(path: string, ids: ReadonlySet<string>): void {
  keep(
    path,
    noteReviewOf(path).filter((c) => !ids.has(c.id)),
  )
}

export function clearNoteReview(path: string): void {
  keep(path, [])
}

// Told when a note's review changes; the way to stop is what this returns.
export function onNoteReviewChange(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

// The comments of a note's review, read again whenever one changes.
export function useNoteReview(path: string | null): NoteComment[] {
  const [, setTick] = useState(0)
  useEffect(() => onNoteReviewChange(() => setTick((n) => n + 1)), [])
  return path === null ? [] : noteReviewOf(path)
}
