import { useCallback } from 'react'
import {
  commonFolder,
  readActivity,
  shownPath,
  type Action,
  type Activity,
  type SessionStats,
} from '../domain/activity.ts'
import { transport } from '../transport/index.ts'
import { useLoad } from '../state/useLoad.ts'

const MAX_DETAIL = 20_000

const KIND_LABEL: Record<Action['kind'], string> = {
  read: 'read',
  write: 'new file',
  edit: 'edit',
  command: 'run',
  search: 'search',
  message: 'said',
  prompt: 'you',
  thinking: 'thought',
  other: 'tool',
  error: 'error',
}

function statsText(harness: Activity['harness'], stats: SessionStats): string {
  const parts: string[] = [harness]
  if (stats.turns !== null) parts.push(`${stats.turns} turns`)
  if (stats.durationMs !== null) parts.push(`${(stats.durationMs / 1000).toFixed(1)} s`)
  if (stats.costUsd !== null && stats.costUsd > 0)
    parts.push(`$${stats.costUsd.toFixed(stats.costUsd < 0.01 ? 4 : 2)}`)
  if (stats.inputTokens !== null || stats.outputTokens !== null) {
    parts.push(`${stats.inputTokens ?? 0} in / ${stats.outputTokens ?? 0} out tokens`)
  }
  return parts.join(' · ')
}

// What came of an action. A change to a file has its added and removed lines
// colored.
function Detail({ action }: { action: Action }) {
  if (action.detail === null || action.detail === '') return null
  const text =
    action.detail.length > MAX_DETAIL ? `${action.detail.slice(0, MAX_DETAIL)}\n…` : action.detail
  const isDiff = action.kind === 'edit' || action.kind === 'write'
  return (
    <pre className="activity-detail mono">
      {isDiff
        ? text.split('\n').map((line, i) => (
            <span
              key={i}
              className="diff-line"
              data-change={line.startsWith('+') ? 'add' : line.startsWith('-') ? 'del' : undefined}
            >
              {line}
              {'\n'}
            </span>
          ))
        : text}
    </pre>
  )
}

function ActionRow({
  action,
  folder,
  expanded = false,
}: {
  action: Action
  folder: string
  // Every row open, whatever it is by default.
  expanded?: boolean
}) {
  const head = (
    <>
      <span className="activity-kind" data-kind={action.kind}>
        {KIND_LABEL[action.kind]}
      </span>
      <span>{action.title}</span>
      {action.target !== null && (
        <span className="mono activity-target" title={action.target}>
          {action.kind === 'command' || action.kind === 'search'
            ? action.target
            : shownPath(action.target, folder)}
        </span>
      )}
      {action.status !== 'ok' && action.kind !== 'error' && (
        <span className="activity-status" data-status={action.status}>
          {action.status}
        </span>
      )}
    </>
  )
  if (action.detail === null || action.detail === '') {
    return <div className="activity-row">{head}</div>
  }
  return (
    // The key makes a change of `expanded` apply to rows that were opened or closed by hand.
    <details
      key={String(expanded)}
      className="activity-row"
      open={
        expanded ||
        action.kind === 'message' ||
        action.kind === 'prompt' ||
        action.status === 'failed'
      }
    >
      <summary>{head}</summary>
      <Detail action={action} />
    </details>
  )
}

// The files an activity changed and its actions: what a session did, or what a
// conversation has done so far.
export function ActivityBody({
  activity,
  empty,
  expanded = false,
}: {
  activity: Activity
  // Said when there is nothing in it.
  empty: string
  expanded?: boolean
}) {
  const { actions, changes } = activity
  const folder = commonFolder([
    ...changes.map((c) => c.path),
    ...actions
      .filter((a) => a.kind === 'read' || a.kind === 'write' || a.kind === 'edit')
      .flatMap((a) => (a.target === null ? [] : [a.target])),
  ])
  return (
    <>
      {changes.length > 0 && (
        <div className="chips" aria-label="Files changed">
          {changes.map((c) => (
            <span key={c.path} className="chip mono" title={c.path}>
              {c.change === 'add' ? '+' : c.change === 'delete' ? '−' : '~'}{' '}
              {shownPath(c.path, folder)}
            </span>
          ))}
        </div>
      )}
      {actions.length === 0 ? (
        <p className="muted small">{empty}</p>
      ) : (
        <div className="activity-list">
          {actions.map((action, i) => (
            <ActionRow key={i} action={action} folder={folder} expanded={expanded} />
          ))}
        </div>
      )}
    </>
  )
}

// What the agent did in one session: the files it changed, its commands and
// what it said.
export function ActivityView({ path }: { path: string }) {
  const load = useCallback(() => transport.readText(path).then(readActivity), [path])
  const { state } = useLoad(load)
  if (state.status === 'loading') return <p className="muted small">Loading the session…</p>
  if (state.status === 'failed') {
    return <p className="muted small">The transcript could not be read: {state.error}</p>
  }
  const { harness, stats } = state.data
  return (
    <div className="activity">
      <p className="muted small">{statsText(harness, stats)}</p>
      <ActivityBody
        activity={state.data}
        empty={
          harness === 'unknown'
            ? 'This transcript is in a form the app does not know.'
            : 'The transcript records no actions, only how the session ended.'
        }
      />
    </div>
  )
}
