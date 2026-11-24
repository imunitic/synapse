import { describe, expect, it } from 'vitest'
import { commentCounts, composeNoteReview, orphaned, type NoteComment } from './note-review.ts'
import type { OutlineHeading } from './outline.ts'

const OUTLINE: OutlineHeading[] = [
  { path: 'Target', title: 'Target', depth: 1 },
  { path: 'Target::Evidence', title: 'Evidence', depth: 2 },
  { path: 'Target::Fix', title: 'Fix', depth: 2 },
]

function comment(over: Partial<NoteComment>): NoteComment {
  return { id: 'c1', section: 'Target::Evidence', text: 'Say more.', ...over }
}

const RULE_START = 'To change the note, read the whole note with `synapse vault-read`'

describe('orphaned', () => {
  it('names the comments whose section is not in the outline, never whole-note ones', () => {
    const comments = [
      comment({ id: 'a' }),
      comment({ id: 'b', section: 'Target::Gone' }),
      comment({ id: 'c', section: null }),
    ]
    expect(orphaned(comments, OUTLINE)).toEqual(new Set(['b']))
  })
})

describe('commentCounts', () => {
  it('counts the comments by section and leaves out whole-note comments', () => {
    const counts = commentCounts([
      comment({ id: 'a' }),
      comment({ id: 'b' }),
      comment({ id: 'c', section: 'Target::Fix' }),
      comment({ id: 'd', section: null }),
    ])
    expect(counts).toEqual(
      new Map([
        ['Target::Evidence', 2],
        ['Target::Fix', 1],
      ]),
    )
  })
})

describe('composeNoteReview', () => {
  it('opens with the note and sends a section comment with its path and its text indented', () => {
    const text = composeNoteReview(
      'notes/a.md',
      [comment({ text: 'Say more.\nAnd cite it.' })],
      OUTLINE,
    )
    expect(
      text.startsWith(
        "Review of the vault note notes/a.md.\nPlease address each comment, then verify the note's structure.\n\n",
      ),
    ).toBe(true)
    expect(text).toContain('1. Section: Target::Evidence\n   Say more.\n   And cite it.\n\n')
  })

  it('sends a whole-note comment as Whole note', () => {
    const text = composeNoteReview('a.md', [comment({ section: null, text: 'Shorter.' })], OUTLINE)
    expect(text).toContain('1. Whole note\n   Shorter.\n\n')
  })

  it('sends an orphaned comment as Whole note and says which section it was about', () => {
    const text = composeNoteReview(
      'a.md',
      [comment({ section: 'Target::Gone', text: 'Fix it.' })],
      OUTLINE,
    )
    expect(text).toContain(
      '1. Whole note\n   (This was about the section Target::Gone, which is no longer in the note.)\n   Fix it.\n\n',
    )
    expect(text).not.toContain('Section: Target::Gone')
  })

  it('numbers the comments in order with a blank line between them', () => {
    const text = composeNoteReview(
      'a.md',
      [
        comment({ id: 'a', text: 'One.' }),
        comment({ id: 'b', section: null, text: 'Two.' }),
        comment({ id: 'c', section: 'Target::Fix', text: 'Three.' }),
      ],
      OUTLINE,
    )
    expect(text).toContain(
      '1. Section: Target::Evidence\n   One.\n\n2. Whole note\n   Two.\n\n3. Section: Target::Fix\n   Three.\n\n',
    )
  })

  it('ends with the editing rule, once', () => {
    const text = composeNoteReview(
      'a.md',
      [comment({ id: 'a' }), comment({ id: 'b', section: null })],
      OUTLINE,
    )
    expect(text.split(RULE_START)).toHaveLength(2)
    const rule = text.slice(text.indexOf(RULE_START))
    expect(rule).toContain('`synapse vault-write`')
    expect(rule).toContain('Do not use `synapse vault-patch`')
    expect(rule).toContain('`synapse vault-doc-map`')
    expect(text.endsWith('rather than by re-reading the changed region.')).toBe(true)
    expect(text.indexOf(RULE_START)).toBeGreaterThan(text.indexOf('2. Whole note'))
  })
})
