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
    if (stream.match(/^(?:Pipeline|System|Agent|Prompt|End)\b/)) return 'keyword'
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
    { tag: tags.comment, color: 'var(--faint)', fontStyle: 'italic' },
    { tag: tags.keyword, color: 'var(--accent-text)', fontWeight: '600' },
    { tag: tags.string, color: 'var(--good)' },
    { tag: tags.propertyName, color: 'var(--info)' },
    { tag: tags.operator, color: 'var(--muted)' },
    { tag: tags.number, color: 'var(--caution)' },
  ]),
)

export const editorTheme = EditorView.theme(
  {
    '&': {
      color: 'var(--text)',
      backgroundColor: 'var(--code-bg)',
      fontSize: '0.8125rem',
      border: '1px solid var(--border-strong)',
      borderRadius: '8px',
    },
    '&.cm-focused': { outline: '2px solid var(--accent-text)', outlineOffset: '2px' },
    '.cm-content': { fontFamily: 'var(--mono)', caretColor: 'var(--caret)', padding: '8px 0' },
    '.cm-cursor': { borderLeftColor: 'var(--caret)' },
    '.cm-scroller': { overflow: 'auto', minHeight: '220px', maxHeight: '460px' },
    '.cm-gutters': { backgroundColor: 'var(--code-bg)', color: 'var(--faint)', border: 'none' },
    '.cm-activeLine': { backgroundColor: 'var(--active-line)' },
    '.cm-activeLineGutter': { backgroundColor: 'var(--active-line)' },
    '.cm-selectionBackground, &.cm-focused .cm-selectionBackground': {
      backgroundColor: 'var(--selection)',
    },
    '.cm-tooltip': {
      backgroundColor: 'var(--card)',
      color: 'var(--text)',
      border: '1px solid var(--border-strong)',
      borderRadius: '6px',
    },
  },
  { dark: true },
)
