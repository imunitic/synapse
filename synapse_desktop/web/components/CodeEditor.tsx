import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands'
import { bracketMatching } from '@codemirror/language'
import { lintGutter, setDiagnostics } from '@codemirror/lint'
import { EditorState } from '@codemirror/state'
import { EditorView, highlightActiveLine, keymap, lineNumbers } from '@codemirror/view'
import { useEffect, useRef } from 'react'
import type { Mark } from '../domain/drafts.ts'
import { jsonLanguage, rainbowBrackets } from './editor/json-language.ts'
import {
  editingHeight,
  editorTheme,
  readingHeight,
  synapseHighlight,
  synapseLanguage,
} from './editor/synapse-language.ts'

const languages = {
  synapse: [synapseLanguage, synapseHighlight],
  json: [jsonLanguage, rainbowBrackets],
  plain: [],
}

const NO_MARKS: readonly Mark[] = []
const ignoreChange = () => {}

// A text editor for a definition. It is given the text to start with and says
// what the text becomes; `marks` underline what is wrong, at places in the text
// that is there now.
export function CodeEditor({
  initial,
  onChange = ignoreChange,
  marks = NO_MARKS,
  label,
  language = 'synapse',
  replacement = null,
  readOnly = false,
}: {
  initial: string
  onChange?: (text: string) => void
  marks?: readonly Mark[]
  label: string
  // How the text is colored: as a definition, as JSON, or not at all.
  language?: 'synapse' | 'json' | 'plain'
  // Text to put in place of what is there, once for each id. It is one change
  // in the editor's history, so undoing it brings back what was written.
  replacement?: { id: number; text: string } | null
  // Whether the text can only be read, selected and copied. Such an editor has no undo history,
  // no binding of Tab, no marks and no highlight of the cursor's line, and is as tall as its
  // text, up to most of the window.
  readOnly?: boolean
}) {
  const host = useRef<HTMLDivElement>(null)
  const view = useRef<EditorView | null>(null)
  const changed = useRef(onChange)
  const replaced = useRef(0)

  useEffect(() => {
    changed.current = onChange
  }, [onChange])

  useEffect(() => {
    if (host.current === null) return
    const editor = new EditorView({
      parent: host.current,
      state: EditorState.create({
        doc: initial,
        extensions: [
          // The text stays editable to the browser, so that it takes focus and the keyboard
          // moves the cursor in it.
          EditorState.readOnly.of(readOnly),
          lineNumbers(),
          readOnly ? [] : [history(), highlightActiveLine(), lintGutter()],
          bracketMatching(),
          keymap.of(readOnly ? defaultKeymap : [...defaultKeymap, ...historyKeymap, indentWithTab]),
          languages[language],
          editorTheme,
          readOnly ? readingHeight : editingHeight,
          EditorView.contentAttributes.of({ 'aria-label': label }),
          EditorView.updateListener.of((update) => {
            if (update.docChanged) changed.current(update.state.doc.toString())
          }),
        ],
      }),
    })
    view.current = editor
    return () => {
      editor.destroy()
      view.current = null
    }
  }, [initial, label, language, readOnly])

  useEffect(() => {
    const editor = view.current
    if (editor === null || replacement === null || replacement.id === replaced.current) return
    replaced.current = replacement.id
    editor.dispatch({
      changes: { from: 0, to: editor.state.doc.length, insert: replacement.text },
    })
  }, [replacement])

  useEffect(() => {
    const editor = view.current
    // Setting marks, even none, adds the lint extension to an editor.
    if (editor === null || readOnly) return
    const length = editor.state.doc.length
    editor.dispatch(
      setDiagnostics(
        editor.state,
        marks
          .filter((m) => m.from <= length)
          .map((m) => ({
            from: m.from,
            to: Math.min(m.to, length),
            severity: m.severity,
            message: m.message,
          })),
      ),
    )
  }, [marks, readOnly])

  return <div ref={host} className="code-editor" />
}
