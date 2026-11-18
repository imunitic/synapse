import { beforeEach, describe, expect, it } from 'vitest'
import type { ReviewComment } from '../domain/review.ts'
import {
  addComment,
  clearReview,
  editComment,
  onReviewChange,
  removeComment,
  reviewOf,
} from './reviews.ts'
import {
  onTerminalInputChange,
  registerTerminal,
  setHarness,
  terminalInput,
} from './terminal-input.ts'

const comment: Omit<ReviewComment, 'id'> = {
  path: 'src/a.ts',
  commit: null,
  side: 'new',
  start: 1,
  end: 2,
  quote: ['+a', '+b'],
  more: 0,
  text: 'First.',
}

beforeEach(() => {
  clearReview('s1')
  clearReview('s2')
})

describe('a session review', () => {
  it('gathers comments in the order they are written, each session apart', () => {
    addComment('s1', comment)
    addComment('s1', { ...comment, text: 'Second.' })
    addComment('s2', { ...comment, text: 'Other.' })
    expect(reviewOf('s1').map((c) => c.text)).toEqual(['First.', 'Second.'])
    expect(reviewOf('s2').map((c) => c.text)).toEqual(['Other.'])
    expect(new Set(reviewOf('s1').map((c) => c.id)).size).toBe(2)
  })

  it('edits and removes a comment, and is emptied when cleared', () => {
    addComment('s1', comment)
    addComment('s1', { ...comment, text: 'Second.' })
    const [first, second] = reviewOf('s1')
    editComment('s1', first!.id, 'Changed.')
    expect(reviewOf('s1').map((c) => c.text)).toEqual(['Changed.', 'Second.'])
    removeComment('s1', second!.id)
    expect(reviewOf('s1').map((c) => c.text)).toEqual(['Changed.'])
    clearReview('s1')
    expect(reviewOf('s1')).toEqual([])
  })

  it('tells those who listen, until they stop', () => {
    let told = 0
    const stop = onReviewChange(() => (told += 1))
    addComment('s1', comment)
    clearReview('s1')
    stop()
    addComment('s1', comment)
    expect(told).toBe(2)
  })
})

describe('the terminal of a session', () => {
  it('is registered with how to send to it, says whether a harness runs, and goes', () => {
    const pasted: string[] = []
    let told = 0
    const stop = onTerminalInputChange(() => (told += 1))
    const unregister = registerTerminal('s1', {
      send: (t) => pasted.push(t),
      submits: false,
      harness: false,
    })
    expect(terminalInput('s1')?.harness).toBe(false)
    setHarness('s1', true)
    setHarness('s1', true)
    expect(terminalInput('s1')?.harness).toBe(true)
    terminalInput('s1')?.send('review')
    expect(pasted).toEqual(['review'])
    unregister()
    expect(terminalInput('s1')).toBeNull()
    expect(told).toBe(3)
    stop()
  })

  it('is not let go by a view that was replaced by another for the same session', () => {
    const first = registerTerminal('s2', { send: () => undefined, submits: false, harness: false })
    registerTerminal('s2', { send: () => undefined, submits: true, harness: true })
    first()
    expect(terminalInput('s2')?.harness).toBe(true)
  })
})
