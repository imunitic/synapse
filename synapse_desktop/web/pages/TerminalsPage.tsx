import { useCapabilities } from '../state/capabilities.ts'
import { useRef, useState } from 'react'
import { CloseIcon, PlusIcon } from '../components/icons.tsx'
import { TerminalView } from '../components/TerminalView.tsx'
import { isLiveRun, terminalName, type TerminalSession } from '../state/state.ts'
import { useTabDrag } from '../layout/use-tab-drag.ts'

// The box a terminal tab turns into to be named: Enter or leaving it keeps the name, Escape keeps
// the old one, and a blank name gives the session back its title.
function RenameBox({ name, onDone }: { name: string; onDone: (name: string | null) => void }) {
  // Escape and Enter end it before the box loses focus, which must not end it a second time.
  const done = useRef(false)
  const finish = (value: string | null) => {
    if (done.current) return
    done.current = true
    onDone(value)
  }
  return (
    <input
      className="terminal-tab-input"
      aria-label={`New name for ${name}`}
      defaultValue={name}
      maxLength={100}
      autoFocus
      onFocus={(event) => event.currentTarget.select()}
      onKeyDown={(event) => {
        if (event.key === 'Enter') finish(event.currentTarget.value)
        if (event.key === 'Escape') finish(null)
      }}
      onBlur={(event) => finish(event.currentTarget.value)}
    />
  )
}

// The terminals: a tab for each session, which goes on while another tab or page
// shows. A tab is named by double-clicking it, and put in another order by dragging it or with Alt
// and the arrow keys.
export function TerminalsPage({
  sessions: all,
  activeId,
  visible,
  onSelect,
  onClose,
  onEnded,
  onClaimed,
  onRename,
  onMove,
  onRun,
  onNew,
  waiting,
}: {
  waiting: ReadonlyMap<string, string>
  sessions: readonly TerminalSession[]
  activeId: string | null
  visible: boolean
  onSelect: (id: string) => void
  onClose: (id: string) => void
  onEnded: (id: string) => void
  onClaimed: (id: string) => void
  onRename: (id: string, name: string) => void
  onMove: (id: string, to: number) => void
  onRun: (id: string, executionId: string) => void
  onNew: () => void
}) {
  const capabilities = useCapabilities()
  // A run's terminal is shown on the run's page.
  const sessions = all.filter((s) => s.kind !== 'Pipeline')
  // The tab being named, if one is.
  const [naming, setNaming] = useState<string | null>(null)
  const row = useRef<HTMLDivElement>(null)
  const { dragging, press, markOf } = useTabDrag({
    row,
    tabSelector: ':scope > .terminal-tab',
    ids: sessions.map((s) => s.id),
    onMove,
  })
  return (
    <div className="page full terminals-page" hidden={!visible}>
      <div ref={row} className="terminal-tabs" role="tablist" aria-label="Terminal tabs">
        {sessions.map((session, index) => (
          <span
            key={session.id}
            className="terminal-tab"
            data-selected={session.id === activeId}
            data-dragging={dragging === session.id ? true : undefined}
            data-drop={markOf(index)}
            onPointerDown={(event) => press(event, session.id)}
          >
            {naming === session.id ? (
              <RenameBox
                name={terminalName(session)}
                onDone={(name) => {
                  setNaming(null)
                  if (name !== null) onRename(session.id, name)
                }}
              />
            ) : (
              <button
                role="tab"
                aria-selected={session.id === activeId}
                title="Double-click to rename"
                onClick={() => onSelect(session.id)}
                onDoubleClick={() => setNaming(session.id)}
                onKeyDown={(event) => {
                  if (!event.altKey) return
                  const step = event.key === 'ArrowLeft' ? -1 : event.key === 'ArrowRight' ? 1 : 0
                  if (step === 0) return
                  event.preventDefault()
                  onMove(session.id, index + step)
                }}
              >
                {terminalName(session)}
                {session.executionId !== undefined && waiting.has(session.executionId) && (
                  <span className="attention-dot" role="img" aria-label="Waiting for you" />
                )}
              </button>
            )}
            <button
              className="icon-button"
              aria-label={`${isLiveRun(session) ? 'Stop' : 'Close'} ${terminalName(session)}`}
              onClick={() => {
                // Ending a run that is going on stops it, so it is asked.
                if (
                  !isLiveRun(session) ||
                  window.confirm(`Stop the run of ${terminalName(session)}? Its agent is ended.`)
                ) {
                  onClose(session.id)
                }
              }}
            >
              <CloseIcon />
            </button>
          </span>
        ))}
        {capabilities.shell && (
          <button className="icon-button" aria-label="New shell" onClick={onNew}>
            <PlusIcon />
          </button>
        )}
      </div>
      {sessions.map((session) => (
        <TerminalView
          key={session.id}
          session={session}
          visible={visible && session.id === activeId}
          onClose={() => onClose(session.id)}
          onEnded={() => onEnded(session.id)}
          onClaimed={() => onClaimed(session.id)}
          onRun={(executionId) => onRun(session.id, executionId)}
          waitingFor={
            session.executionId === undefined ? null : (waiting.get(session.executionId) ?? null)
          }
        />
      ))}
    </div>
  )
}
