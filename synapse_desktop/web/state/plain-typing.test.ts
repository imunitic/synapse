import { describe, expect, it } from 'vitest'
import { makePlain, type Field } from './plain-typing.ts'

function field(
  tagName: string,
  set: Record<string, string> = {},
): Field & {
  attributes: Record<string, string>
} {
  const attributes = { ...set }
  return {
    tagName,
    attributes,
    hasAttribute: (name) => name in attributes,
    setAttribute: (name, value) => {
      attributes[name] = value
    },
  }
}

describe('makePlain', () => {
  it('turns capitalizing and correcting off on an input and a text area', () => {
    for (const tag of ['INPUT', 'TEXTAREA']) {
      const f = field(tag)
      makePlain(f)
      expect(f.attributes).toEqual({ autocapitalize: 'off', autocorrect: 'off' })
    }
  })

  it('keeps what a field sets itself, and leaves other elements alone', () => {
    const prose = field('TEXTAREA', { autocapitalize: 'sentences' })
    makePlain(prose)
    expect(prose.attributes).toEqual({ autocapitalize: 'sentences', autocorrect: 'off' })
    const div = field('DIV')
    makePlain(div)
    expect(div.attributes).toEqual({})
  })
})
