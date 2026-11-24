import { beforeEach, describe, expect, it } from 'vitest'
import type { NoteComment } from '../domain/note-review.ts'
import {
  addNoteComment,
  clearNoteReview,
  editNoteComment,
  noteReviewOf,
  onNoteReviewChange,
  removeNoteComment,
  removeNoteComments,
} from './note-reviews.ts'

const A = 'designs/a.md'
const B = 'designs/b.md'
const comment: Omit<NoteComment, 'id'> = { section: 'A::Evidence', text: 'First.' }

beforeEach(() => {
  clearNoteReview(A)
  clearNoteReview(B)
})

describe('a note review', () => {
  it('adds comments in the order they are written, each with its own id', () => {
    addNoteComment(A, comment)
    addNoteComment(A, { section: null, text: 'Second.' })
    expect(noteReviewOf(A).map((c) => [c.section, c.text])).toEqual([
      ['A::Evidence', 'First.'],
      [null, 'Second.'],
    ])
    expect(new Set(noteReviewOf(A).map((c) => c.id)).size).toBe(2)
  })

  it('edits a comment, keeping its section', () => {
    addNoteComment(A, comment)
    const [first] = noteReviewOf(A)
    editNoteComment(A, first!.id, 'Changed.')
    expect(noteReviewOf(A)).toEqual([{ ...first, text: 'Changed.' }])
  })

  it('removes a comment', () => {
    addNoteComment(A, comment)
    addNoteComment(A, { ...comment, text: 'Second.' })
    const [first] = noteReviewOf(A)
    removeNoteComment(A, first!.id)
    expect(noteReviewOf(A).map((c) => c.text)).toEqual(['Second.'])
  })

  it('removes only the comments sent, keeping one written since', () => {
    addNoteComment(A, comment)
    addNoteComment(A, { section: null, text: 'Second.' })
    const sent = new Set(noteReviewOf(A).map((c) => c.id))
    addNoteComment(A, { section: 'A::Fix', text: 'Written while sending.' })
    removeNoteComments(A, sent)
    expect(noteReviewOf(A).map((c) => c.text)).toEqual(['Written while sending.'])
  })

  it('is emptied when cleared', () => {
    addNoteComment(A, comment)
    clearNoteReview(A)
    expect(noteReviewOf(A)).toEqual([])
  })

  it('keeps two notes apart', () => {
    addNoteComment(A, comment)
    addNoteComment(B, { section: null, text: 'Other.' })
    clearNoteReview(A)
    expect(noteReviewOf(A)).toEqual([])
    expect(noteReviewOf(B).map((c) => c.text)).toEqual(['Other.'])
  })

  it('tells those who listen, until they stop', () => {
    let told = 0
    const stop = onNoteReviewChange(() => (told += 1))
    addNoteComment(A, comment)
    clearNoteReview(A)
    stop()
    addNoteComment(A, comment)
    expect(told).toBe(2)
  })
})
