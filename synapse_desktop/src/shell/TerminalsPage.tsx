import { FitAddon } from '@xterm/addon-fit'
import { scaledPixels } from '../domain/text-size.ts'
import { currentTextSize, onTextSizeChange } from './text-size.ts'
import { Terminal } from '@xterm/xterm'
import '@xterm/xterm/css/xterm.css'
import { useEffect, useMemo, useRef, useState } from 'react'
import type { TerminalHandle, TerminalTranscript } from '../../shared/transport.ts'
import { readSessionLog } from '../domain/activity.ts'
import { transport } from '../transport/index.ts'
import { ActivityBody } from './ActivityView.tsx'
import { CloseIcon, PlusIcon } from './icons.tsx'
import type { TerminalSession } from './state.ts'

// A conversation that is followed: the lines of the session file of a harness.
interface Followed {
  id: string
  harness: 'Claude' | 'Codex'
  cwd: string
  lines: string[]
}

// What the harness in the terminal has been told and has done, read from its
// session file as it grows, with every tool call and its result in full. It stays
// at the bottom while it is there, and shows what is new.
function ConversationBox({ followed }: { followed: readonly Followed[] }) {
  const [chosen, setChosen] = useState<string | null>(null)
  const [open, setOpen] = useState(true)
  const [expanded, setExpanded] = useState(false)
  const body = useRef<HTMLDivElement>(null)
  // Whether the person is at the bottom, which is where new lines show.
  const atBottom = useRef(true)
  const current = followed.find((f) => f.id === chosen) ?? followed.at(-1)
  const lineCount = current?.lines.length ?? 0

  const activity = useMemo(
    () =>
      current === undefined ? null : readSessionLog(current.harness, current.lines.join('\n')),
    // The lines only grow, so their number says when they are not the ones that were read.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [current?.id, lineCount],
  )

  useEffect(() => {
    const element = body.current
    if (element !== null && atBottom.current) element.scrollTop = element.scrollHeight
  }, [activity, expanded, open])

  if (current === undefined || activity === null) return null
  return (
    <section className="conversation" aria-label="Conversation" data-open={open}>
      <div className="conversation-head">
        <h2 className="card-title">Conversation</h2>
        {followed.length > 1 &&
          followed.map((f, i) => (
            <button
              key={f.id}
              className="chip"
              aria-pressed={f.id === current.id}
              onClick={() => setChosen(f.id)}
            >
              {f.harness} {i + 1}
            </button>
          ))}
        <span className="conversation-actions">
          <button className="link" aria-pressed={expanded} onClick={() => setExpanded(!expanded)}>
            {expanded ? 'Collapse all' : 'Expand all'}
          </button>
          <button className="link" aria-expanded={open} onClick={() => setOpen(!open)}>
            {open ? 'Hide' : 'Show'}
          </button>
        </span>
      </div>
      {open && (
        <div
          ref={body}
          className="conversation-body"
          onScroll={(event) => {
            const e = event.currentTarget
            atBottom.current = e.scrollHeight - e.scrollTop - e.clientHeight < 24
          }}
        >
          <ActivityBody
            activity={activity}
            expanded={expanded}
            empty={`Nothing has been said in this ${current.harness} session yet.`}
          />
        </div>
      )}
    </section>
  )
}

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
  const [followed, setFollowed] = useState<Followed[]>([])

  useEffect(() => {
    const element = host.current
    if (element === null) return
    const terminal = new Terminal({
      cursorBlink: true,
      fontSize: scaledPixels(13, currentTextSize()),
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
    // A terminal draws its own text, so it is told when the size of the text changes.
    const unlisten = onTextSizeChange((percent) => {
      terminal.options.fontSize = scaledPixels(13, percent)
      if (element.offsetParent !== null) fitter.fit()
    })

    // The terminal has a size once it is on the page: ask for the session then.
    const frame = requestAnimationFrame(() => {
      if (gone) return
      fitter.fit()
      handle = transport.openTerminal(
        {
          kind: session.kind,
          ...(session.cwd === '' ? {} : { cwd: session.cwd }),
          ...(session.task === undefined ? {} : { task: session.task }),
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
          onTranscript: (event: TerminalTranscript) => {
            setFollowed((all) =>
              event.kind === 'source'
                ? all.some((f) => f.id === event.id)
                  ? all
                  : [...all, { id: event.id, harness: event.harness, cwd: event.cwd, lines: [] }]
                : all.map((f) =>
                    f.id === event.id ? { ...f, lines: [...f.lines, ...event.lines] } : f,
                  ),
            )
          },
        },
      )
      for (const data of typed.splice(0)) handle.write(data)
    })

    return () => {
      gone = true
      cancelAnimationFrame(frame)
      observer.disconnect()
      unlisten()
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
      <ConversationBox followed={followed} />
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
