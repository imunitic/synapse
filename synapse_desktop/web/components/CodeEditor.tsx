import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands'
import { bracketMatching } from '@codemirror/language'
import { lintGutter, setDiagnostics } from '@codemirror/lint'
import { EditorState } from '@codemirror/state'
import { EditorView, highlightActiveLine, keymap, lineNumbers } from '@codemirror/view'
import { useEffect, useRef } from 'react'
import type { Mark } from '../domain/drafts.ts'
import { editorTheme, synapseHighlight, synapseLanguage } from './editor/synapse-language.ts'

// A text editor for a definition. It is given the text to start with and says
// what the text becomes; `marks` underline what is wrong, at places in the text
// that is there now.
export function CodeEditor({
  initial,
  onChange,
  marks,
  label,
  highlight = true,
  replacement = null,
}: {
  initial: string
  onChange: (text: string) => void
  marks: readonly Mark[]
  label: string
  highlight?: boolean
  // Text to put in place of what is there, once for each id. It is one change
  // in the editor's history, so undoing it brings back what was written.
  replacement?: { id: number; text: string } | null
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
          lineNumbers(),
          history(),
          highlightActiveLine(),
          bracketMatching(),
          lintGutter(),
          keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
          highlight ? [synapseLanguage, synapseHighlight] : [],
          editorTheme,
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
  }, [initial, label, highlight])

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
    if (editor === null) return
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
  }, [marks])

  return <div ref={host} className="code-editor" />
}
