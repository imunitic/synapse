// Colors for the definition language: comments, keywords, attribute names,
// strings, arrows and numbers. It is only for looking at; what is wrong with a
// text is said by the program.

import { HighlightStyle, StreamLanguage, syntaxHighlighting } from '@codemirror/language'
import type { StreamParser } from '@codemirror/language'
import { EditorView } from '@codemirror/view'
import { tags } from '@lezer/highlight'

interface State {
  // Inside a block of text between triple quotes, which may run over lines.
  triple: boolean
}

const parser: StreamParser<State> = {
  startState: () => ({ triple: false }),
  token(stream, state) {
    if (state.triple) {
      if (stream.skipTo('"""')) {
        stream.match('"""')
        state.triple = false
      } else {
        stream.skipToEnd()
      }
      return 'string'
    }
    if (stream.eatSpace()) return null
    if (stream.match('--')) {
      stream.skipToEnd()
      return 'comment'
    }
    if (stream.match('"""')) {
      if (stream.skipTo('"""')) stream.match('"""')
      else {
        state.triple = true
        stream.skipToEnd()
      }
      return 'string'
    }
    if (stream.match(/^"(?:[^"\\]|\\.)*"/)) return 'string'
    if (stream.match(/^(?:Pipeline|System|Agent|End)\b/)) return 'keyword'
    if (stream.match(/^[A-Z][A-Za-z_]*(?=\s*=>)/)) return 'propertyName'
    if (stream.match(/^(?:->|=>)/)) return 'operator'
    if (stream.match(/^\d+/)) return 'number'
    if (stream.match(/^[A-Za-z_][A-Za-z0-9_]*/)) return 'variableName'
    stream.next()
    return null
  },
}

export const synapseLanguage = StreamLanguage.define(parser)

export const synapseHighlight = syntaxHighlighting(
  HighlightStyle.define([
    { tag: tags.comment, color: '#8b8b95', fontStyle: 'italic' },
    { tag: tags.keyword, color: '#b0a6ff', fontWeight: '600' },
    { tag: tags.string, color: '#86efac' },
    { tag: tags.propertyName, color: '#93c5fd' },
    { tag: tags.operator, color: '#a1a1aa' },
    { tag: tags.number, color: '#fcd34d' },
  ]),
)

export const editorTheme = EditorView.theme(
  {
    '&': {
      color: '#e4e4e7',
      backgroundColor: '#18181b',
      fontSize: '0.8125rem',
      border: '1px solid #3a3a42',
      borderRadius: '8px',
    },
    '&.cm-focused': { outline: '2px solid #b0a6ff', outlineOffset: '2px' },
    '.cm-content': { fontFamily: 'var(--mono)', caretColor: '#ffffff', padding: '8px 0' },
    '.cm-cursor': { borderLeftColor: '#ffffff' },
    '.cm-scroller': { overflow: 'auto', minHeight: '220px', maxHeight: '460px' },
    '.cm-gutters': { backgroundColor: '#18181b', color: '#8b8b95', border: 'none' },
    '.cm-activeLine': { backgroundColor: 'rgba(255, 255, 255, 0.04)' },
    '.cm-activeLineGutter': { backgroundColor: 'rgba(255, 255, 255, 0.04)' },
    '.cm-selectionBackground, &.cm-focused .cm-selectionBackground': {
      backgroundColor: '#3b3470',
    },
    '.cm-tooltip': {
      backgroundColor: '#232328',
      color: '#e4e4e7',
      border: '1px solid #3a3a42',
      borderRadius: '6px',
    },
  },
  { dark: true },
)
