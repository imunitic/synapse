import { useCallback, useState } from 'react'
import {
  commonFolder,
  readActivity,
  shownPath,
  type Action,
  type Activity,
  type SessionStats,
  KIND_NAMES,
  kindCounts,
  type ActionKind,
  type FileChange,
  actionsOnFile,
  samePath,
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
// A toggle chip for each kind of action there is, with how many; several can be on, and none on is
// every kind. Kept apart from the list, so that it can stay in view while the list scrolls.
export function KindChips({
  actions,
  kinds,
  onKinds,
}: {
  actions: readonly Action[]
  kinds: ReadonlySet<ActionKind>
  onKinds: (kinds: ReadonlySet<ActionKind>) => void
}) {
  if (actions.length === 0) return null
  return (
    <div className="chips activity-kinds" role="group" aria-label="Kinds of action shown">
      {kindCounts(actions).map(({ kind, count }) => {
        const on = kinds.has(kind)
        return (
          <button
            key={kind}
            className="chip chip-button"
            aria-pressed={on}
            onClick={() => {
              const next = new Set(kinds)
              if (on) next.delete(kind)
              else next.add(kind)
              onKinds(next)
            }}
          >
            {KIND_NAMES[kind]} {count}
          </button>
        )
      })}
    </div>
  )
}

// Up to this many files changed are listed at once; more start folded, behind how many there are.
const FILES_OPEN = 3

const MARKS: Record<FileChange['change'], string> = { add: '+', update: '~', delete: '−' }

// The files the conversation changed: one line each, its name and then its folder, cut short to fit,
// with the whole path when pointed at. A file is a button that shows its diff, where there is one.
function ChangedFiles({
  changes,
  folder,
  onShowChange,
  file,
  onFile,
}: {
  changes: readonly FileChange[]
  folder: string
  onShowChange?: (path: string) => void
  // The file whose actions alone are shown, and choosing one: given, a file's name chooses it, and
  // its diff is a button of its own.
  file: string | null
  onFile?: (path: string) => void
}) {
  const [open, setOpen] = useState(changes.length <= FILES_OPEN)
  return (
    <section className="activity-files" aria-label="Files changed">
      <button className="link small" aria-expanded={open} onClick={() => setOpen(!open)}>
        {open ? '▾' : '▸'} {changes.length} {changes.length === 1 ? 'file' : 'files'} changed
      </button>
      {open &&
        changes.map((c) => {
          const shown = shownPath(c.path, folder)
          const cut = shown.lastIndexOf('/')
          const content = (
            <>
              <span className="activity-file-mark">{MARKS[c.change]} </span>
              <span className="activity-file-name">
                {cut === -1 ? shown : shown.slice(cut + 1)}
              </span>
              {cut !== -1 && <span className="activity-file-folder"> {shown.slice(0, cut)}</span>}
            </>
          )
          if (onFile !== undefined) {
            return (
              <span key={c.path} className="activity-file-row">
                <button
                  className="activity-file mono small"
                  aria-pressed={file !== null && samePath(file, c.path)}
                  title={`Show what this conversation did to ${c.path}`}
                  onClick={() => onFile(c.path)}
                >
                  {content}
                </button>
                {onShowChange !== undefined && (
                  <button
                    className="link small"
                    title={`Show the diff of ${c.path}`}
                    onClick={() => onShowChange(c.path)}
                  >
                    Diff
                  </button>
                )}
              </span>
            )
          }
          return onShowChange === undefined ? (
            <span key={c.path} className="activity-file mono small" title={c.path}>
              {content}
            </span>
          ) : (
            <button
              key={c.path}
              className="activity-file mono small"
              title={`Show what changed in ${c.path}`}
              onClick={() => onShowChange(c.path)}
            >
              {content}
            </button>
          )
        })}
    </section>
  )
}

export function ActivityBody({
  activity,
  empty,
  expanded = false,
  onShowChange,
  kinds = null,
  file = null,
  onFile,
}: {
  activity: Activity
  // Said when there is nothing in it.
  empty: string
  expanded?: boolean
  // A file that was changed is a button, which shows its diff where there is one: given the whole
  // path the activity names it by.
  onShowChange?: (path: string) => void
  // The kinds of action shown; none, or an empty set, shows every action.
  kinds?: ReadonlySet<ActionKind> | null
  // One file whose actions alone are shown, opened; and choosing one by its name in the files.
  file?: string | null
  onFile?: (path: string) => void
}) {
  const { actions: all, changes } = activity
  const filtering = kinds !== null && kinds.size > 0
  const ofFile = file === null ? all : actionsOnFile(all, file)
  const actions = filtering ? ofFile.filter((a) => kinds.has(a.kind)) : ofFile
  const folder = commonFolder([
    ...changes.map((c) => c.path),
    ...actions
      .filter((a) => a.kind === 'read' || a.kind === 'write' || a.kind === 'edit')
      .flatMap((a) => (a.target === null ? [] : [a.target])),
  ])
  return (
    <>
      {changes.length > 0 && (
        <ChangedFiles
          changes={changes}
          folder={folder}
          onShowChange={onShowChange}
          file={file}
          {...(onFile === undefined ? {} : { onFile })}
        />
      )}
      {actions.length === 0 ? (
        <p className="muted small">{all.length === 0 ? empty : 'No action of the kinds chosen.'}</p>
      ) : (
        <div className="activity-list">
          {actions.map((action, i) => (
            <ActionRow
              key={i}
              action={action}
              folder={folder}
              expanded={expanded || file !== null}
            />
          ))}
        </div>
      )}
    </>
  )
}

// What the agent did in one session: the files it changed, its commands and
// what it said.
export function ActivityView({
  path,
  onShowChange,
}: {
  path: string
  onShowChange?: (path: string) => void
}) {
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
        onShowChange={onShowChange}
        empty={
          harness === 'unknown'
            ? 'This transcript is in a form the app does not know.'
            : 'The transcript records no actions, only how the session ended.'
        }
      />
    </div>
  )
}
