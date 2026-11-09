import { describe, expect, it } from 'vitest'
import { changeCount, diffLines, withContext } from './diff.ts'

const kinds = (before: string, after: string) =>
  diffLines(before, after).map((line) =>
    line.kind === 'gap' ? '~' : `${line.kind[0]}:${line.text}`,
  )

describe('the lines a change made', () => {
  it('has nothing added or removed for a text that is the same', () => {
    expect(kinds('a\nb\n', 'a\nb\n')).toEqual(['s:a', 's:b'])
    expect(changeCount(diffLines('a\n', 'a\n'))).toEqual({ added: 0, removed: 0 })
  })

  it('has the lines that were added and removed, in the order of the text', () => {
    expect(kinds('a\nb\nc\n', 'a\nx\nc\nd\n')).toEqual(['s:a', 'r:b', 'a:x', 's:c', 'a:d'])
    expect(changeCount(diffLines('a\nb\nc\n', 'a\nx\nc\nd\n'))).toEqual({ added: 2, removed: 1 })
  })

  it('handles a text with nothing in it, and a last line with no line feed', () => {
    expect(kinds('', 'a\nb')).toEqual(['a:a', 'a:b'])
    expect(kinds('a\nb', '')).toEqual(['r:a', 'r:b'])
    expect(kinds('a\nb', 'a\nb\n')).toEqual(['s:a', 's:b'])
  })

  it('finds a line moved down as one removal and one addition around what stayed', () => {
    expect(kinds('1\n2\n3\n4\n', '2\n3\n4\n1\n')).toEqual(['r:1', 's:2', 's:3', 's:4', 'a:1'])
  })

  it('is a removal and an addition of the whole middle when there are too many lines to compare', () => {
    const before = Array.from({ length: 2500 }, (_, i) => `a${i}`).join('\n')
    const after = Array.from({ length: 2500 }, (_, i) => `b${i}`).join('\n')
    const lines = diffLines(`top\n${before}\nbottom\n`, `top\n${after}\nbottom\n`)
    expect(lines[0]).toEqual({ kind: 'same', text: 'top' })
    expect(lines.at(-1)).toEqual({ kind: 'same', text: 'bottom' })
    expect(changeCount(lines)).toEqual({ added: 2500, removed: 2500 })
  })
})

describe('the lines shown with their context', () => {
  it('keeps the changed lines and some of those around them, and says how many it left out', () => {
    const before = Array.from({ length: 12 }, (_, i) => `l${i}`).join('\n') + '\n'
    const after = before.replace('l6', 'CHANGED')
    const shown = withContext(diffLines(before, after), 2)
    expect(
      shown.map((l) => (l.kind === 'gap' ? `gap ${l.hidden}` : `${l.kind[0]}:${l.text}`)),
    ).toEqual(['gap 4', 's:l4', 's:l5', 'r:l6', 'a:CHANGED', 's:l7', 's:l8', 'gap 3'])
  })

  it('shows no gap when the changes are close, and nothing when there are none', () => {
    expect(withContext(diffLines('a\nb\n', 'a\nB\n'), 3).some((l) => l.kind === 'gap')).toBe(false)
    expect(withContext(diffLines('a\nb\n', 'a\nb\n'), 3)).toEqual([{ kind: 'gap', hidden: 2 }])
  })
})
