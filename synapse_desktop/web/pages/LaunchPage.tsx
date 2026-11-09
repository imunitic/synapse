import { useCallback, useState } from 'react'
import type { Harness, PastSession, TerminalKind, Workspace } from '../../shared/transport.ts'
import { timeAgo } from '../domain/format.ts'
import { launchView, rememberLaunchView, type LaunchView } from '../domain/launch-view.ts'
import { workspaceLabel, workspaceNames } from '../domain/workspaces.ts'
import { useConfig } from '../state/config.tsx'
import { useHarnesses } from '../state/diagnosis.tsx'
import { TERMINAL_LABELS } from '../state/state.ts'
import { useLoad } from '../state/useLoad.ts'
import { transport } from '../transport/index.ts'

const HARNESSES: readonly Harness[] = ['Claude', 'Codex', 'Opencode']

type Start = (kind: TerminalKind, cwd: string, resume?: string) => void

function PastSessionList({
  harness,
  sessions,
  onStart,
}: {
  harness: Harness
  sessions: readonly PastSession[]
  onStart: Start
}) {
  const now = new Date()
  const folders = workspaceNames(sessions.map((s) => s.path))
  const label = TERMINAL_LABELS[harness]
  if (sessions.length === 0) return <p className="muted small">No past sessions.</p>
  return (
    <ul className="workspace-list">
      {sessions.map((session, index) => (
        <li key={session.id} className="past-session">
          <span className="past-session-title" title={session.title ?? undefined}>
            {session.title ?? 'No title'}
          </span>
          <span className="muted small mono workspace-path" title={session.path}>
            {folders[index]}
          </span>
          {session.lastUsed !== null && (
            <span className="muted small">{timeAgo(session.lastUsed, now)}</span>
          )}
          <button
            className="secondary"
            aria-label={`Resume ${label} session ${session.title ?? session.id}`}
            onClick={() => onStart(harness, session.path, session.id)}
          >
            Resume
          </button>
        </li>
      ))}
    </ul>
  )
}

function ShellCard({ onStart }: { onStart: Start }) {
  const { state: config } = useConfig()
  // Where a shell starts: what was typed here, else the default of the settings; empty is
  // the home folder.
  const [typed, setTyped] = useState<string | null>(null)
  const folder = typed ?? (config.status === 'ready' ? (config.config.terminalFolder ?? '') : '')
  return (
    <section className="card" aria-label="Shell">
      <h2 className="card-title">Shell</h2>
      <form
        className="launch-form"
        onSubmit={(event) => {
          event.preventDefault()
          onStart('Shell', folder.trim())
        }}
      >
        <label className="field">
          <span className="muted small">Start in</span>
          <input
            className="mono"
            value={folder}
            placeholder="your home folder"
            onChange={(event) => setTyped(event.target.value)}
          />
        </label>
        <button className="primary" type="submit">
          New shell
        </button>
      </form>
    </section>
  )
}

function FolderList({
  harness,
  workspaces,
  onStart,
}: {
  harness: Harness
  workspaces: readonly Workspace[]
  onStart: Start
}) {
  const label = TERMINAL_LABELS[harness]
  const [other, setOther] = useState('')
  const now = new Date()
  const names = workspaceNames(workspaces.map((w) => w.path))
  return (
    <>
      {workspaces.length === 0 ? (
        <p className="muted small">No folder yet. Start in one below.</p>
      ) : (
        <ul className="workspace-list">
          {workspaces.map((workspace, index) => {
            const { parent } = workspaceLabel(workspace.path)
            return (
              <li key={workspace.path}>
                <button
                  className="workspace"
                  title={workspace.path}
                  aria-label={`${label} in ${workspace.path}`}
                  onClick={() => onStart(harness, workspace.path)}
                >
                  <span className="workspace-name">{names[index]}</span>
                  <span className="muted small mono workspace-path">{parent}</span>
                  {workspace.lastUsed !== null && (
                    <span className="muted small">{timeAgo(workspace.lastUsed, now)}</span>
                  )}
                </button>
              </li>
            )
          })}
        </ul>
      )}
      <form
        className="launch-form"
        onSubmit={(event) => {
          event.preventDefault()
          if (other.trim() !== '') onStart(harness, other.trim())
        }}
      >
        <label className="field">
          <span className="muted small">Another folder</span>
          <input
            className="mono"
            value={other}
            placeholder="/path/to/a/folder"
            onChange={(event) => setOther(event.target.value)}
          />
        </label>
        <button className="primary" type="submit" disabled={other.trim() === ''}>
          Start
        </button>
      </form>
      <p className="muted small">A folder it has not worked in is one it may ask to trust.</p>
    </>
  )
}

const VIEWS: readonly { view: LaunchView; label: string }[] = [
  { view: 'folders', label: 'Folders' },
  { view: 'sessions', label: 'Sessions' },
]

function HarnessCard({
  harness,
  workspaces,
  sessions,
  onStart,
}: {
  harness: Harness
  workspaces: readonly Workspace[]
  sessions: readonly PastSession[]
  onStart: Start
}) {
  const label = TERMINAL_LABELS[harness]
  const missing = useHarnesses().reason(harness)
  const [view, setView] = useState<LaunchView>(() => launchView(harness))
  const counts = { folders: workspaces.length, sessions: sessions.length }
  function choose(next: LaunchView) {
    setView(next)
    rememberLaunchView(harness, next)
  }
  return (
    <section className="card" aria-label={label}>
      <h2 className="card-title">{label}</h2>
      {missing !== null ? (
        <p className="muted small">Not found. {missing}</p>
      ) : (
        <>
          <div className="subtabs" role="tablist" aria-label={`${label} lists`}>
            {VIEWS.map(({ view: v, label: name }) => (
              <button
                key={v}
                className="subtab"
                role="tab"
                aria-selected={view === v}
                aria-pressed={view === v}
                onClick={() => choose(v)}
              >
                {name} <span className="muted">{counts[v]}</span>
              </button>
            ))}
          </div>
          <div role="tabpanel" aria-label={`${label} ${view}`}>
            {view === 'folders' ? (
              <FolderList harness={harness} workspaces={workspaces} onStart={onStart} />
            ) : (
              <PastSessionList harness={harness} sessions={sessions} onStart={onStart} />
            )}
          </div>
        </>
      )}
    </section>
  )
}

// Where a terminal is started: a shell, or a harness in a folder it already works in.
export function LaunchPage({ onStart }: { onStart: Start }) {
  const load = useCallback(() => transport.listWorkspaces(), [])
  const { state } = useLoad(load)
  const loadSessions = useCallback(() => transport.listSessions(), [])
  const { state: sessions } = useLoad(loadSessions)
  return (
    <div className="page">
      <div className="page-head">
        <h1 className="page-title">Terminals</h1>
      </div>
      <ShellCard onStart={onStart} />
      {state.status === 'failed' && (
        <p className="error" role="alert">
          The folders the harnesses work in could not be read. {state.error}
        </p>
      )}
      {HARNESSES.map((harness) => (
        <HarnessCard
          key={harness}
          harness={harness}
          workspaces={state.status === 'ready' ? state.data[harness] : []}
          sessions={sessions.status === 'ready' ? sessions.data[harness] : []}
          onStart={onStart}
        />
      ))}
    </div>
  )
}
