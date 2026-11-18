// What a note is in a line, from its front matter: its id, its status, when it was updated and
// its tags. The rest of its properties are there to be opened, so that the text is not pushed
// down the page by a table of them.

import { timeAgo } from './format.ts'

export interface NoteSummary {
  id: string | null
  status: string | null
  updated: string | null
  tags: string[]
}

function text(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value : null
}

export function noteSummary(
  frontmatter: Record<string, unknown> | null | undefined,
  now: Date,
): NoteSummary {
  const found = frontmatter ?? {}
  const updated = text(found.updated)
  const ago = updated === null ? '' : timeAgo(updated, now)
  return {
    // A task note has a task id and a note id, and the task id is the one it is known by.
    id: text(found.task_id) ?? text(found.note_id),
    status: text(found.status),
    updated: ago === '' ? null : ago,
    tags: Array.isArray(found.tags)
      ? found.tags.filter((tag): tag is string => typeof tag === 'string')
      : [],
  }
}
