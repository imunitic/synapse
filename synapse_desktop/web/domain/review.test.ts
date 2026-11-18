import { describe, expect, it } from 'vitest'
import { composeReview, placeOf, quoteOf, QUOTED, type ReviewComment } from './review.ts'
import type { PatchLine } from './unified-diff.ts'

function line(kind: PatchLine['kind'], text: string, n: number): PatchLine {
  return {
    kind,
    text,
    oldNumber: kind === 'add' ? null : n,
    newNumber: kind === 'remove' ? null : n,
  }
}

function comment(over: Partial<ReviewComment>): ReviewComment {
  return {
    id: 'c1',
    path: 'src/foo.ts',
    commit: null,
    side: 'new',
    start: 42,
    end: 48,
    quote: [],
    more: 0,
    text: 'Fix this.',
    ...over,
  }
}

describe('quoteOf', () => {
  it('keeps each line with its sign', () => {
    expect(
      quoteOf([
        line('remove', 'return null', 4),
        line('add', 'return x', 4),
        line('context', '}', 5),
      ]),
    ).toEqual({ quote: ['-return null', '+return x', ' }'], more: 0 })
  })

  it('quotes at most twenty lines and says how many more there were', () => {
    const lines = Array.from({ length: QUOTED + 5 }, (_, i) => line('add', `l${i}`, i + 1))
    const { quote, more } = quoteOf(lines)
    expect(quote).toHaveLength(QUOTED)
    expect(quote[0]).toBe('+l0')
    expect(more).toBe(5)
  })
})

describe('placeOf', () => {
  it('is the path and the range, one line alone, and says when the lines were removed', () => {
    expect(placeOf(comment({}))).toBe('src/foo.ts:42-48')
    expect(placeOf(comment({ start: 12, end: 12 }))).toBe('src/foo.ts:12')
    expect(placeOf(comment({ side: 'old', start: 3, end: 5 }))).toBe('src/foo.ts:3-5 (removed)')
  })
})

describe('composeReview', () => {
  it('numbers the comments, each with its place, its lines and its text, apart by a blank line', () => {
    const text = composeReview([
      comment({
        quote: ['-    return null', '+    return cached ?? null'],
        text: 'This swallows the error: return it instead.',
      }),
      comment({
        id: 'c2',
        path: 'docs/setup.md',
        commit: 'abc1234def5678',
        start: 12,
        end: 12,
        quote: ['+Run npm install first.'],
        text: 'Say which npm version.\nAnd where.',
      }),
    ])
    expect(text).toBe(
      [
        'Review of your changes. Please address each comment.',
        '',
        '1. src/foo.ts:42-48',
        '   > -    return null',
        '   > +    return cached ?? null',
        '   This swallows the error: return it instead.',
        '',
        '2. In commit abc1234, docs/setup.md:12',
        '   > +Run npm install first.',
        '   Say which npm version.',
        '   And where.',
      ].join('\n'),
    )
  })

  it('says how many lines past the quoted ones a comment is on', () => {
    expect(composeReview([comment({ quote: ['+a'], more: 7 })])).toContain(
      '   > +a\n   > ... and 7 more lines',
    )
  })
})
