import { registerTerminal, setHarness } from '../state/terminal-input.ts'
import { setConversations, type FollowedConversation } from '../state/conversations.ts'
import { FitAddon } from '@xterm/addon-fit'
import { scaledPixels } from '../domain/text-size.ts'
import { currentTextSize, onTextSizeChange } from '../state/text-size.ts'
import { onThemeChange } from '../state/theme.ts'
import { Terminal } from '@xterm/xterm'
import '@xterm/xterm/css/xterm.css'
import { useEffect, useRef, useState } from 'react'
import type { TerminalHandle, TerminalTranscript } from '../../shared/transport.ts'
import { mergeSessionLines } from '../domain/activity.ts'
import { transport } from '../transport/index.ts'
import { ensureBaseline, followBaseline } from '../state/change-baselines.ts'
import { terminalName, type TerminalSession } from '../state/state.ts'

// The kinds of session that run a harness from the start.
export const HARNESS_KINDS: ReadonlySet<string> = new Set(['Claude', 'Codex', 'Opencode'])

// One session: an xterm.js terminal and the program in it. The session is asked
// for once the terminal is on the page. When the view goes away it only lets go of
// the session: React does that to every view whose code is swapped in development,
// and the session must not end then. A session is ended where it is closed.
export type TerminalViewProps = {
  session: TerminalSession
  visible: boolean
  onClose: () => void
  onEnded: () => void
  // The host holds the session, so that a view made again for it attaches.
  onClaimed: () => void
  onRun: (executionId: string) => void
  // What the agent of an interactive run said when it handed control to the person, when it did.
  waitingFor: string | null
}

export function TerminalView({
  session,
  visible,
  onClose,
  onEnded,
  onClaimed,
  onRun,
  waitingFor,
}: TerminalViewProps) {
  const host = useRef<HTMLDivElement>(null)
  const fit = useRef<FitAddon | null>(null)
  const term = useRef<Terminal | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const [ended, setEnded] = useState(false)
  const [followed, setFollowed] = useState<FollowedConversation[]>([])

  useEffect(() => {
    const element = host.current
    if (element === null) return
    const terminal = new Terminal({
      cursorBlink: true,
      fontSize: scaledPixels(13, currentTextSize()),
      fontFamily: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace',
      theme: terminalColours(),
    })
    const fitter = new FitAddon()
    terminal.loadAddon(fitter)
    terminal.open(element)
    term.current = terminal
    fit.current = fitter
    // The Changes sidebar sends a review to this session through it: pasted as a person's paste is,
    // in bracketed paste when the program asks for it, so that its line breaks stay in the prompt.
    // It is submitted with Enter only where the session's program is the harness itself: a harness
    // started in a shell may have ended, and the shell would run the lines as commands.
    const submits = HARNESS_KINDS.has(session.kind)
    const unregister = registerTerminal(session.id, {
      send: (text) => {
        terminal.paste(text)
        if (submits) terminal.input('\r')
        terminal.focus()
      },
      submits,
      harness: HARNESS_KINDS.has(session.kind),
    })
    let handle: TerminalHandle | null = null
    let gone = false
    // The terminal takes the focus when its session first starts, and not again when it attaches
    // after a lost connection.
    let focused = false
    // What is typed before the session is asked for waits, and goes to it then.
    const typed: string[] = []
    // A session opened to run a command has it typed, and run, when it starts.
    // A view made again for its session does not type it a second time.
    if (session.command !== undefined && session.attach !== true) {
      typed.push(`${session.command}\n`)
    }

    terminal.onData((data) => (handle === null ? typed.push(data) : handle.write(data)))
    terminal.onResize(({ cols, rows }) => handle?.resize(cols, rows))
    // The size follows the page, when it can be seen.
    const observer = new ResizeObserver(() => {
      if (element.offsetParent !== null) fitter.fit()
    })
    observer.observe(element)
    // A terminal draws its own text, so it is told when the size of the text changes.
    const unlistenTheme = onThemeChange(() => {
      terminal.options.theme = terminalColours()
    })
    const unlisten = onTextSizeChange((percent) => {
      terminal.options.fontSize = scaledPixels(13, percent)
      if (element.offsetParent !== null) fitter.fit()
    })

    // The terminal has a size once it is on the page: ask for the session then.
    const frame = requestAnimationFrame(() => {
      if (gone) return
      fitter.fit()
      // The point its changes are taken from is the folder as it is before the program starts, when
      // the folder is known now; a session that starts in the home folder takes it when it has started.
      const baseline =
        session.attach !== true && session.cwd !== ''
          ? ensureBaseline(transport, session.id, session.cwd)
          : Promise.resolve()
      void baseline.then(() => {
        if (gone) return
        handle = transport.openTerminal(
          {
            session: session.id,
            title: session.title,
            ...(session.attach === true ? { attach: true } : {}),
            kind: session.kind,
            ...(session.cwd === '' ? {} : { cwd: session.cwd }),
            ...(session.task === undefined ? {} : { task: session.task }),
            ...(session.resume === undefined ? {} : { resume: session.resume }),
            ...(session.pipeline === undefined ? {} : { pipeline: session.pipeline }),
            ...(session.input === undefined ? {} : { input: session.input }),
            cols: terminal.cols,
            rows: terminal.rows,
          },
          {
            onStarted: (info) => {
              // The point its changes are taken from: the folder as it is when the session starts.
              void ensureBaseline(transport, session.id, info.cwd)
              setNote(info.note)
              if (!focused && focusIsFree(element)) terminal.focus()
              focused = true
              onClaimed()
            },
            onOutput: (data) => terminal.write(data),
            // The screen as it was drawn replaces what is shown: this one is attached to again.
            onSnapshot: (data) => {
              terminal.reset()
              terminal.write(data)
            },
            onRun,
            onExit: (code) => {
              terminal.write(`\r\n\x1b[2m[the program ended with code ${code}]\x1b[0m\r\n`)
              handle = null
              setEnded(true)
              onEnded()
            },
            onError: (message) => {
              terminal.write(`\r\n\x1b[31m${message}\x1b[0m\r\n`)
              handle = null
              setEnded(true)
              onEnded()
            },
            onTranscript: (event: TerminalTranscript) => {
              // A harness started in this session works in a folder of its own, which is where its
              // changes are, so that is where they are looked for from now on.
              if (event.kind === 'source' && event.cwd !== '') {
                void followBaseline(transport, session.id, event.cwd, event.id)
              }
              setFollowed((all) =>
                event.kind === 'source'
                  ? all.some((f) => f.id === event.id)
                    ? all
                    : [...all, { id: event.id, harness: event.harness, cwd: event.cwd, lines: [] }]
                  : all.map((f) =>
                      f.id === event.id
                        ? { ...f, lines: mergeSessionLines(f.harness, f.lines, event.lines) }
                        : f,
                    ),
              )
            },
          },
        )
        for (const data of typed.splice(0)) handle.write(data)
      })
    })

    return () => {
      gone = true
      cancelAnimationFrame(frame)
      observer.disconnect()
      unlisten()
      unlistenTheme()
      handle?.detach()
      unregister()
      terminal.dispose()
      term.current = null
      fit.current = null
    }
    // A session is started once, with what it was opened with.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // The conversations this session follows are shown in the Activity tab of the Changes sidebar.
  useEffect(() => setConversations(session.id, followed), [session.id, followed])
  useEffect(() => () => setConversations(session.id, []), [session.id])

  // A shell in which a harness was started has its conversation followed: a review goes to it.
  useEffect(() => {
    setHarness(session.id, HARNESS_KINDS.has(session.kind) || followed.length > 0)
  }, [session.id, session.kind, followed.length])

  useEffect(() => {
    if (visible) {
      fit.current?.fit()
      if (!ended) term.current?.focus()
    }
  }, [visible, ended])

  return (
    <div className="terminal-view" hidden={!visible}>
      {waitingFor !== null && (
        <p className="attention-banner" role="status">
          <strong>Waiting for you.</strong>
          {waitingFor !== '' && <span> {waitingFor}</span>}
        </p>
      )}
      <div ref={host} className="terminal-host" aria-label={`Terminal ${terminalName(session)}`} />
      {note !== null && note !== '' && (
        <p className="terminal-note" role="status">
          {note}
        </p>
      )}
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

// A terminal is dark in either theme: the programs in it, Claude Code among them, choose their
// colours for a dark background. Only how dark follows the theme, from --terminal-bg in
// index.css, which xterm.js cannot read itself since it draws on a canvas.
export function terminalColours() {
  const background = getComputedStyle(document.documentElement)
    .getPropertyValue('--terminal-bg')
    .trim()
  return { background: background || '#18181b', foreground: '#e4e4e7', cursor: '#b0a6ff' }
}

// Whether a terminal that has just started may take the focus: not from a text box or a dialog,
// which the person opened while the session was starting and is typing in or answering.
export function focusIsFree(own: HTMLElement): boolean {
  const active = document.activeElement
  if (active === null || active === document.body || own.contains(active)) return true
  if (active.closest('[role="dialog"], [role="alertdialog"]') !== null) return false
  return !(
    active instanceof HTMLInputElement ||
    active instanceof HTMLTextAreaElement ||
    active instanceof HTMLSelectElement ||
    (active instanceof HTMLElement && active.isContentEditable)
  )
}
