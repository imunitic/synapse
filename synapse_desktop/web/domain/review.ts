// A review of an agent's changes, written in the Changes sidebar: comments on lines of a diff,
// gathered and sent to the agent as one prompt, which the person submits. Nothing here is stored in
// the repository.

import type { PatchLine } from './unified-diff.ts'

export interface ReviewComment {
  id: string
  // The file, from the root of the repository.
  path: string
  // The commit the lines are of, for a comment written in the Git tab; none in the Changes tab.
  commit: string | null
  // The name of the repository's folder, when the sidebar shows more than one; none when it shows
  // one, and for a comment kept from before repositories were named.
  repository?: string | null
  // Which file's numbers the range is in: a removed line has only the old one.
  side: 'new' | 'old'
  start: number
  end: number
  // The lines of the range, each with its '+', '-' or ' ' in front, at most QUOTED of them.
  quote: string[]
  // How many lines of the range were past those quoted.
  more: number
  text: string
}

// The most lines a comment quotes: enough to place it, little enough to keep a review short.
export const QUOTED = 20

const SIGNS: Record<PatchLine['kind'], string> = {
  add: '+',
  remove: '-',
  context: ' ',
  note: ' ',
}

// The chosen lines as a comment quotes them.
export function quoteOf(lines: readonly PatchLine[]): { quote: string[]; more: number } {
  const quote = lines.slice(0, QUOTED).map((line) => `${SIGNS[line.kind]}${line.text}`)
  return { quote, more: Math.max(0, lines.length - QUOTED) }
}

// Where a comment is: `src/foo.ts:42-48`, `src/foo.ts:12` for one line, `(removed)` after lines
// that are only in the old file, and `api/src/foo.ts:42` when it names its repository.
export function placeOf(
  comment: Pick<ReviewComment, 'path' | 'side' | 'start' | 'end' | 'repository'>,
): string {
  const lines =
    comment.start === comment.end ? `${comment.start}` : `${comment.start}-${comment.end}`
  const path =
    comment.repository === undefined || comment.repository === null
      ? comment.path
      : `${comment.repository}/${comment.path}`
  return `${path}:${lines}${comment.side === 'old' ? ' (removed)' : ''}`
}

const OPENING = 'Review of your changes. Please address each comment.'

// The prompt a review is sent as: each comment numbered, with its place, the lines it is on and
// what was said of them.
export function composeReview(comments: readonly ReviewComment[]): string {
  const parts = comments.map((comment, index) => {
    const place =
      comment.commit === null
        ? placeOf(comment)
        : `In commit ${comment.commit.slice(0, 7)}, ${placeOf(comment)}`
    const quoted = comment.quote.map((line) => `   > ${line}`)
    if (comment.more > 0) quoted.push(`   > ... and ${comment.more} more lines`)
    const text = comment.text
      .trim()
      .split('\n')
      .map((line) => `   ${line}`)
    return [`${index + 1}. ${place}`, ...quoted, ...text].join('\n')
  })
  return [OPENING, ...parts].join('\n\n')
}
