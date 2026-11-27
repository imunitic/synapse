// Colors for JSON: property names, strings, numbers, booleans and null, from
// the same theme colors as the definition language. Brackets are colored by
// how deep they are, so the eye can find which ones belong together.

import { json } from '@codemirror/lang-json'
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language'
import { RangeSetBuilder } from '@codemirror/state'
import { Decoration, ViewPlugin } from '@codemirror/view'
import type { DecorationSet, EditorView, ViewUpdate } from '@codemirror/view'
import { tags } from '@lezer/highlight'

// How many depths have their own color before the colors start again.
const depthColors = 3

const jsonHighlight = syntaxHighlighting(
  HighlightStyle.define([
    { tag: tags.propertyName, color: 'var(--info)' },
    { tag: tags.string, color: 'var(--good)' },
    { tag: tags.number, color: 'var(--caution)' },
    { tag: tags.bool, color: 'var(--accent-text)' },
    { tag: tags.null, color: 'var(--muted)', fontStyle: 'italic' },
  ]),
)

export const jsonLanguage = [json(), jsonHighlight]

// Every `{`, `}`, `[` and `]` outside a string, with how deep it is: an opening
// bracket and its closing one have the same depth, the outermost is 0. Text
// that does not balance gives depths all the same; a closing bracket with
// nothing open is at depth 0.
export function bracketDepths(text: string): { from: number; depth: number }[] {
  const found: { from: number; depth: number }[] = []
  let depth = 0
  let inString = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (inString) {
      if (c === '\\') i++
      else if (c === '"') inString = false
      continue
    }
    if (c === '"') inString = true
    else if (c === '{' || c === '[') {
      found.push({ from: i, depth })
      depth++
    } else if (c === '}' || c === ']') {
      depth = Math.max(depth - 1, 0)
      found.push({ from: i, depth })
    }
  }
  return found
}

const depthMarks = Array.from({ length: depthColors }, (_, d) =>
  Decoration.mark({ class: `cm-bracket-depth-${d}` }),
)

function decorate(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>()
  for (const { from, depth } of bracketDepths(view.state.doc.toString())) {
    const mark = depthMarks[depth % depthColors]
    if (mark) builder.add(from, from + 1, mark)
  }
  return builder.finish()
}

export const rainbowBrackets = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet
    constructor(view: EditorView) {
      this.decorations = decorate(view)
    }
    update(update: ViewUpdate) {
      if (update.docChanged) this.decorations = decorate(update.view)
    }
  },
  { decorations: (plugin) => plugin.decorations },
)
