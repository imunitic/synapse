// The review each terminal session has in progress: the comments written on its diffs, kept for the
// life of the tab until they are sent to the agent or discarded, so that a page loaded again still
// has them. Nothing here is written to the repository.

import type { ReviewComment } from '../domain/review.ts'

const KEY = 'synapse-desktop.reviews'

function readAll(): Record<string, ReviewComment[]> {
  try {
    const raw = sessionStorage.getItem(KEY)
    const parsed: unknown = raw === null ? {} : JSON.parse(raw)
    return typeof parsed === 'object' && parsed !== null
      ? (parsed as Record<string, ReviewComment[]>)
      : {}
  } catch {
    return {}
  }
}

// Kept for the session of the browser; storage may be missing or full, and then it is kept here.
const kept = new Map<string, ReviewComment[]>()
const listeners = new Set<() => void>()
let counter = 0

export function reviewOf(session: string): ReviewComment[] {
  return kept.get(session) ?? readAll()[session] ?? []
}

function keep(session: string, comments: ReviewComment[]): void {
  if (comments.length === 0) kept.delete(session)
  else kept.set(session, comments)
  try {
    const all = readAll()
    if (comments.length === 0) delete all[session]
    else all[session] = comments
    sessionStorage.setItem(KEY, JSON.stringify(all))
  } catch {
    // Not kept beyond this page.
  }
  for (const listener of listeners) listener()
}

export function addComment(session: string, comment: Omit<ReviewComment, 'id'>): void {
  counter += 1
  keep(session, [...reviewOf(session), { ...comment, id: `${Date.now()}-${counter}` }])
}

export function editComment(session: string, id: string, text: string): void {
  keep(
    session,
    reviewOf(session).map((c) => (c.id === id ? { ...c, text } : c)),
  )
}

export function removeComment(session: string, id: string): void {
  keep(
    session,
    reviewOf(session).filter((c) => c.id !== id),
  )
}

export function clearReview(session: string): void {
  keep(session, [])
}

// Told when a review changes; the way to stop is what this returns.
export function onReviewChange(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}
