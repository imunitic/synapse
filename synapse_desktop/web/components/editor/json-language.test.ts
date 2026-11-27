import { describe, expect, it } from 'vitest'
import { bracketDepths } from './json-language.ts'

describe('bracketDepths', () => {
  it('gives nested brackets their depth, an opening and its closing the same', () => {
    expect(bracketDepths('{"a": [1, {"b": []}]}')).toEqual([
      { from: 0, depth: 0 },
      { from: 6, depth: 1 },
      { from: 10, depth: 2 },
      { from: 16, depth: 3 },
      { from: 17, depth: 3 },
      { from: 18, depth: 2 },
      { from: 19, depth: 1 },
      { from: 20, depth: 0 },
    ])
  })

  it('does not count brackets inside a string', () => {
    expect(bracketDepths('{"a": "[{x}]"}')).toEqual([
      { from: 0, depth: 0 },
      { from: 13, depth: 0 },
    ])
  })

  it('does not end a string at an escaped quote', () => {
    expect(bracketDepths('["a\\"[", ["b"]]')).toEqual([
      { from: 0, depth: 0 },
      { from: 9, depth: 1 },
      { from: 13, depth: 1 },
      { from: 14, depth: 0 },
    ])
  })

  it('does not throw on text that does not balance', () => {
    expect(bracketDepths(']]{[')).toEqual([
      { from: 0, depth: 0 },
      { from: 1, depth: 0 },
      { from: 2, depth: 0 },
      { from: 3, depth: 1 },
    ])
    expect(bracketDepths('{"open')).toEqual([{ from: 0, depth: 0 }])
  })
})
