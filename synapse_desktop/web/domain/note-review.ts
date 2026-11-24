// A review of a vault note, written in the Outline sidebar and on the note page: comments anchored
// to a heading path from `synapse vault-doc-map`, or to the whole note, gathered and sent to an
// agent as one prompt. Nothing here touches the note until the agent's run changes it.

import type { OutlineHeading } from './outline.ts'

export interface NoteComment {
  id: string
  // The heading path the comment is on, as the doc-map names it; null for the whole note.
  section: string | null
  text: string
}

// The ids of the comments whose section is no longer a heading of the note.
export function orphaned(
  comments: readonly NoteComment[],
  outline: readonly OutlineHeading[],
): Set<string> {
  const paths = new Set(outline.map((heading) => heading.path))
  const ids = new Set<string>()
  for (const comment of comments) {
    if (comment.section !== null && !paths.has(comment.section)) ids.add(comment.id)
  }
  return ids
}

// How many comments each section has, by heading path; whole-note comments are not counted.
export function commentCounts(comments: readonly NoteComment[]): Map<string, number> {
  const counts = new Map<string, number>()
  for (const comment of comments) {
    if (comment.section === null) continue
    counts.set(comment.section, (counts.get(comment.section) ?? 0) + 1)
  }
  return counts
}

const RULE = [
  'To change the note, read the whole note with `synapse vault-read`, change it, and write it back',
  'whole with `synapse vault-write`. Do not use `synapse vault-patch`. Afterwards, verify with',
  '`synapse vault-doc-map` that the heading count is what the changes require and that the',
  "note's size is plausible, rather than by re-reading the changed region.",
].join('\n')

function indented(text: string): string[] {
  return text
    .trim()
    .split('\n')
    .map((line) => `   ${line}`)
}

// The prompt a note review is sent as: the opening, each comment numbered with its section (or
// the whole note), its text indented, a blank line between them, and the editing rule last. A
// comment whose section is gone is sent as a whole-note comment that says which section it was on.
export function composeNoteReview(
  path: string,
  comments: readonly NoteComment[],
  outline: readonly OutlineHeading[],
): string {
  const gone = orphaned(comments, outline)
  const opening = [
    `Review of the vault note ${path}.`,
    "Please address each comment, then verify the note's structure.",
  ].join('\n')
  const parts = comments.map((comment, index) => {
    const number = `${index + 1}.`
    if (comment.section === null) return [`${number} Whole note`, ...indented(comment.text)]
    if (gone.has(comment.id)) {
      return [
        `${number} Whole note`,
        `   (This was about the section ${comment.section}, which is no longer in the note.)`,
        ...indented(comment.text),
      ]
    }
    return [`${number} Section: ${comment.section}`, ...indented(comment.text)]
  })
  return [opening, ...parts.map((lines) => lines.join('\n')), RULE].join('\n\n')
}
