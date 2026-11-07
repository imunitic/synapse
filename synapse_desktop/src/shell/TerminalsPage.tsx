import { FitAddon } from '@xterm/addon-fit'
import { Terminal } from '@xterm/xterm'
import '@xterm/xterm/css/xterm.css'
import { useEffect, useRef, useState } from 'react'
import type { TerminalHandle } from '../../shared/transport.ts'
import { transport } from '../transport/index.ts'
import { CloseIcon, PlusIcon } from './icons.tsx'
import type { TerminalSession } from './state.ts'

// One session: an xterm.js terminal and the program in it. The session is asked
// for once the terminal is on the page, and ends with the program or with this
// view, which is kept for as long as the tab is open.
function TerminalView({
  session,
  visible,
  onClose,
}: {
  session: TerminalSession
  visible: boolean
  onClose: () => void
}) {
  const host = useRef<HTMLDivElement>(null)
  const fit = useRef<FitAddon | null>(null)
  const term = useRef<Terminal | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const [ended, setEnded] = useState(false)

  useEffect(() => {
    const element = host.current
    if (element === null) return
    const terminal = new Terminal({
      cursorBlink: true,
      fontSize: 13,
      fontFamily: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace',
      theme: { background: '#18181b', foreground: '#e4e4e7', cursor: '#b0a6ff' },
    })
    const fitter = new FitAddon()
    terminal.loadAddon(fitter)
    terminal.open(element)
    term.current = terminal
    fit.current = fitter
    let handle: TerminalHandle | null = null
    let gone = false
    // What is typed before the session is asked for waits, and goes to it then.
    const typed: string[] = []

    terminal.onData((data) => (handle === null ? typed.push(data) : handle.write(data)))
    terminal.onResize(({ cols, rows }) => handle?.resize(cols, rows))
    // The size follows the page, when it can be seen.
    const observer = new ResizeObserver(() => {
      if (element.offsetParent !== null) fitter.fit()
    })
    observer.observe(element)

    // The terminal has a size once it is on the page: ask for the session then.
    const frame = requestAnimationFrame(() => {
      if (gone) return
      fitter.fit()
      handle = transport.openTerminal(
        {
          kind: session.kind,
          ...(session.cwd === '' ? {} : { cwd: session.cwd }),
          cols: terminal.cols,
          rows: terminal.rows,
        },
        {
          onStarted: (info) => {
            setNote(info.note)
            terminal.focus()
          },
          onOutput: (data) => terminal.write(data),
          onExit: (code) => {
            terminal.write(`\r\n\x1b[2m[the program ended with code ${code}]\x1b[0m\r\n`)
            handle = null
            setEnded(true)
          },
          onError: (message) => {
            terminal.write(`\r\n\x1b[31m${message}\x1b[0m\r\n`)
            handle = null
            setEnded(true)
          },
        },
      )
      for (const data of typed.splice(0)) handle.write(data)
    })

    return () => {
      gone = true
      cancelAnimationFrame(frame)
      observer.disconnect()
      handle?.close()
      terminal.dispose()
      term.current = null
      fit.current = null
    }
    // A session is started once, with what it was opened with.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    if (visible) {
      fit.current?.fit()
      if (!ended) term.current?.focus()
    }
  }, [visible, ended])

  return (
    <div className="terminal-view" hidden={!visible}>
      {note !== null && <p className="muted small terminal-note">{note}</p>}
      <div ref={host} className="terminal-host" aria-label={`Terminal ${session.title}`} />
      {ended && (
        <p className="terminal-ended" role="status">
          <span>The session ended.</span>
          <button className="link" onClick={onClose}>
            Close the tab
          </button>
        </p>
      )}
    </div>
  )
}

// The terminals: a tab for each session, which goes on while another tab or page
// shows.
export function TerminalsPage({
  sessions,
  activeId,
  visible,
  onSelect,
  onClose,
  onNew,
}: {
  sessions: readonly TerminalSession[]
  activeId: string | null
  visible: boolean
  onSelect: (id: string) => void
  onClose: (id: string) => void
  onNew: () => void
}) {
  return (
    <div className="page full terminals-page" hidden={!visible}>
      <div className="subtabs terminal-tabs" role="tablist" aria-label="Terminal tabs">
        {sessions.map((session) => (
          <span key={session.id} className="terminal-tab" data-selected={session.id === activeId}>
            <button
              role="tab"
              aria-selected={session.id === activeId}
              onClick={() => onSelect(session.id)}
            >
              {session.title}
            </button>
            <button
              className="icon-button"
              aria-label={`Close ${session.title}`}
              onClick={() => onClose(session.id)}
            >
              <CloseIcon />
            </button>
          </span>
        ))}
        <button className="icon-button" aria-label="New shell" onClick={onNew}>
          <PlusIcon />
        </button>
      </div>
      {sessions.map((session) => (
        <TerminalView
          key={session.id}
          session={session}
          visible={visible && session.id === activeId}
          onClose={() => onClose(session.id)}
        />
      ))}
    </div>
  )
}
