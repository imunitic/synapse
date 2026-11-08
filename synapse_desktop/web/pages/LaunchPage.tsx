import { useCallback, useState } from 'react'
import type { Harness, TerminalKind, Workspace } from '../../shared/transport.ts'
import { timeAgo } from '../domain/format.ts'
import { workspaceLabel, workspaceNames } from '../domain/workspaces.ts'
import { useConfig } from '../state/config.tsx'
import { useHarnesses } from '../state/diagnosis.tsx'
import { TERMINAL_LABELS } from '../state/state.ts'
import { useLoad } from '../state/useLoad.ts'
import { transport } from '../transport/index.ts'

const HARNESSES: readonly Harness[] = ['Claude', 'Codex', 'Opencode']

function ShellCard({ onStart }: { onStart: (kind: TerminalKind, cwd: string) => void }) {
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

function HarnessCard({
  harness,
  workspaces,
  onStart,
}: {
  harness: Harness
  workspaces: readonly Workspace[]
  onStart: (kind: TerminalKind, cwd: string) => void
}) {
  const label = TERMINAL_LABELS[harness]
  const missing = useHarnesses().reason(harness)
  const [other, setOther] = useState('')
  const now = new Date()
  const names = workspaceNames(workspaces.map((w) => w.path))
  return (
    <section className="card" aria-label={label}>
      <h2 className="card-title">{label}</h2>
      {missing !== null ? (
        <p className="muted small">Not found. {missing}</p>
      ) : (
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
      )}
    </section>
  )
}

// Where a terminal is started: a shell, or a harness in a folder it already works in.
export function LaunchPage({ onStart }: { onStart: (kind: TerminalKind, cwd: string) => void }) {
  const load = useCallback(() => transport.listWorkspaces(), [])
  const { state } = useLoad(load)
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
          onStart={onStart}
        />
      ))}
    </div>
  )
}
