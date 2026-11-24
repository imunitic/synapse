import { useMemo, useRef, useState } from 'react'
import type { PointerEvent } from 'react'
import { RefreshIcon } from '../components/icons.tsx'
import { FileChanges } from '../components/FileChanges.tsx'
import { baseName, pathMatches, sinceLabel, type ChangesBase } from '../domain/changes.ts'
import { parseUnifiedDiff } from '../domain/unified-diff.ts'
import type { ChangesTab } from '../state/state.ts'
import type { CommitListState, CommitViewState } from '../state/useCommits.ts'
import type { ChangeGroup, ChangesState } from '../state/useChanges.ts'
import { GitTab } from './GitTab.tsx'
import { ActivityTab } from './ActivityTab.tsx'
import type { ActionKind } from '../domain/activity.ts'
import { FolderBar } from './FolderBar.tsx'
import { ReviewBar, useReview } from './ReviewBar.tsx'
import type { DiffReview } from '../components/FileChanges.tsx'
import type { ReviewComment } from '../domain/review.ts'
import { addComment } from '../state/reviews.ts'
import type { FileDiff } from '../domain/unified-diff.ts'
import { transport } from '../transport/index.ts'

const TAB_NAMES: Record<ChangesTab, string> = {
  changes: 'Changes',
  git: 'Git',
  activity: 'Activity',
}

const WIDTH_KEY = 'synapse-desktop.changes-width'
export const MIN_WIDTH = 300
export const MAX_WIDTH = 900
const START_WIDTH = 460

export function readWidth(): number {
  try {
    const stored = Number(localStorage.getItem(WIDTH_KEY))
    if (stored >= MIN_WIDTH && stored <= MAX_WIDTH) return stored
  } catch {
    // Not kept.
  }
  return START_WIDTH
}

export function keepWidth(width: number): void {
  try {
    localStorage.setItem(WIDTH_KEY, String(width))
  } catch {
    // Not kept.
  }
}

// What the sidebar has of a terminal session's commits: the Git tab, which only a session has.
export interface SessionActivity {
  kinds: readonly ActionKind[]
  onKinds: (kinds: ActionKind[]) => void
  file: string | null
  onFile: (file: string | null) => void
  onShowChange: (path: string) => void
}

export interface SessionGit {
  tab: ChangesTab
  onTab: (tab: ChangesTab) => void
  list: CommitListState
  view: CommitViewState
  commit: string | null
  readFile: ((path: string) => Promise<FileDiff | null>) | null
  onCommit: (commit: string | null) => void
  onLoadMore: () => void
  onRefresh: () => void
}

// The changes of what is being looked at: a list of the files, and the diff of the one chosen. A
// run has a part for each recorded step, which is chosen above the list. A file that is new is a row
// that is opened to be read. A terminal session also has a Git tab with the commits of its branch.
export function ChangesSidebar({
  state,
  onRefresh,
  live,
  focusVisit,
  focusFile,
  onBase,
  git,
  reviewSession,
  activity,
}: {
  state: ChangesState
  onRefresh: () => void
  // A step of the run is running: its changes are asked for after each tool call, and on Refresh.
  live: boolean
  // The visit of a run that was asked for, which is the one shown until another is chosen.
  focusVisit: number | null
  // The file an activity asked for, by the whole path it names it with.
  focusFile: string | null
  // What a session's changes are to be against was chosen.
  onBase: (base: ChangesBase) => void
  // The Git tab of a terminal session; none on a run's page, which has its changes only.
  git: SessionGit | null
  // The terminal session whose diffs can be commented on, for its review; none on a run's page.
  reviewSession: string | null
  // The Activity tab of a terminal session: the kinds of action it shows, and showing a file the
  // conversation changed; none on a run's page.
  activity: SessionActivity | null
}) {
  const [width, setWidth] = useState(readWidth)
  const dragging = useRef(false)
  const [chosen, setChosen] = useState<{ visit: number | null; id: string } | null>(null)

  const groups: ChangeGroup[] = state.status === 'ready' ? state.groups : []
  // What was chosen counts only while the visit asked for is the one it was chosen under.
  const kept = chosen !== null && chosen.visit === focusVisit ? chosen : null
  const group: ChangeGroup | null =
    groups.find((g) => g.id === kept?.id) ??
    (focusVisit === null ? undefined : groups.find((g) => g.visit === focusVisit)) ??
    groups[0] ??
    null
  const files = group?.set.files ?? []
  const origin = state.status === 'ready' ? state.origin : null
  const originFolder = origin?.folder ?? null
  const originTree = origin?.tree ?? null
  // A new file of a session is read from its folder; a run has every file's content in its patch.
  const readFile = useMemo(
    () =>
      originFolder === null || originTree === null
        ? null
        : (path: string) =>
            transport
              .diffChanges(originFolder, originTree, path)
              .then((answer) => parseUnifiedDiff(answer.patch)[0] ?? null),
    [originFolder, originTree],
  )

  const onGit = git !== null && git.tab === 'git'
  const onActivity = git !== null && git.tab === 'activity' && activity !== null
  const comments = useReview(reviewSession)
  // The file of a comment chosen in the review bar, shown in the tab it was written in.
  const [shown, setShown] = useState<{ path: string; commit: string | null } | null>(null)
  const reviewFor = (commit: string | null): DiffReview | null =>
    reviewSession === null
      ? null
      : {
          commit,
          comments,
          onComment: (comment) => addComment(reviewSession, comment),
        }
  const showComment = (comment: ReviewComment) => {
    setShown({ path: comment.path, commit: comment.commit })
    if (git === null) return
    git.onTab(comment.commit === null ? 'changes' : 'git')
    if (comment.commit !== null) git.onCommit(comment.commit)
  }
  const changesFocus = focusFile ?? (shown?.commit === null ? shown.path : null)
  // A file asked for that is not among the changes shown, by its name: the comparison chosen may not
  // have it, such as a file that is committed when only what is not committed is shown.
  const missing =
    changesFocus !== null && !files.some((f) => pathMatches(changesFocus, f.path))
      ? baseName(changesFocus)
      : null

  const startDrag = (event: PointerEvent<HTMLDivElement>) => {
    dragging.current = true
    event.currentTarget.setPointerCapture(event.pointerId)
  }
  const drag = (event: PointerEvent<HTMLDivElement>) => {
    if (!dragging.current) return
    setWidth(Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, window.innerWidth - event.clientX)))
  }
  const endDrag = () => {
    if (!dragging.current) return
    dragging.current = false
    keepWidth(width)
  }

  return (
    <aside className="changes" aria-label="Changes" style={{ width }}>
      <div
        className="changes-resize"
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize the Changes sidebar"
        onPointerDown={startDrag}
        onPointerMove={drag}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
      />
      <div className="panel-header">
        {git === null ? (
          <h2 className="panel-title">Changes</h2>
        ) : (
          <div className="changes-tabs" role="tablist" aria-label="What the sidebar shows">
            {(['changes', 'git', 'activity'] as const).map((tab) => (
              <button
                key={tab}
                className="changes-tab"
                role="tab"
                aria-selected={git.tab === tab}
                onClick={() => git.onTab(tab)}
              >
                {TAB_NAMES[tab]}
              </button>
            ))}
          </div>
        )}
        {/* The activity follows as it goes: there is nothing to read again. */}
        {!onActivity && (
          <button
            className="icon-button"
            aria-label={onGit ? 'Read the commits again' : 'Read the changes again'}
            title={onGit ? 'Read the commits again' : 'Read the changes again'}
            onClick={onGit ? git.onRefresh : onRefresh}
          >
            <RefreshIcon />
          </button>
        )}
      </div>
      {reviewSession !== null && !onActivity && <FolderBar session={reviewSession} />}
      {onActivity && reviewSession !== null && (
        <ActivityTab
          session={reviewSession}
          kinds={activity.kinds}
          onKinds={activity.onKinds}
          file={activity.file}
          onFile={activity.onFile}
          onShowChange={activity.onShowChange}
        />
      )}
      {onGit && (
        <GitTab
          list={git.list}
          view={git.view}
          commit={git.commit}
          readFile={git.readFile}
          onCommit={git.onCommit}
          onLoadMore={git.onLoadMore}
          review={reviewFor(git.commit)}
          focusFile={shown !== null && shown.commit === git.commit ? shown.path : null}
        />
      )}
      {!onGit && !onActivity && (
        <>
          {state.status === 'none' && (
            <p className="panel-empty">
              Changes are shown for a terminal session or a run: open one to see what an agent
              changed in its folder.
            </p>
          )}
          {state.status === 'waiting' && (
            <p className="panel-empty">The starting point of this session is not taken yet.</p>
          )}
          {state.status === 'loading' && <p className="panel-empty">Reading the changes…</p>}
          {state.status === 'no-repository' && (
            <p className="panel-empty">
              This folder is not in a git repository, so there is no diff to show.
            </p>
          )}
          {state.status === 'failed' && (
            <p className="panel-empty" role="alert">
              {state.error}
            </p>
          )}
          {state.status === 'ready' && state.kind === 'session' && (
            <div className="changes-steps" role="group" aria-label="Compared with">
              <button
                className="changes-step"
                aria-pressed={state.base === 'start'}
                onClick={() => onBase('start')}
              >
                {sinceLabel(state.position)}
              </button>
              <button
                className="changes-step"
                aria-pressed={state.base === 'commit'}
                onClick={() => onBase('commit')}
              >
                Not committed
              </button>
            </div>
          )}
          {state.status === 'ready' && state.kind === 'session' && missing !== null && (
            <p className="panel-empty" role="status">
              {missing} has no changes{' '}
              {state.base === 'commit'
                ? 'that are not committed. If it was committed, its commit is in the Git tab.'
                : `${sinceLabel(state.position).toLowerCase()}.`}
            </p>
          )}
          {state.status === 'ready' && files.length === 0 && (
            <p className="panel-empty">
              {state.kind === 'run'
                ? 'No step of this run recorded a change.'
                : state.base === 'commit'
                  ? 'Everything is committed.'
                  : state.position === null
                    ? 'Nothing has changed since this session started.'
                    : `Nothing has changed ${sinceLabel(state.position).toLowerCase()}.`}
            </p>
          )}
          {state.status === 'ready' && live && state.kind === 'run' && (
            <div className="changes-steps">
              <button className="changes-step" onClick={onRefresh}>
                Refresh
              </button>
            </div>
          )}
          {state.status === 'ready' && groups.length > 1 && (
            <div className="changes-steps" role="group" aria-label="Steps">
              {groups.map((g) => (
                <button
                  key={g.id}
                  className="changes-step"
                  aria-pressed={g.id === group?.id}
                  onClick={() => setChosen({ visit: focusVisit, id: g.id })}
                >
                  {g.label}
                </button>
              ))}
            </div>
          )}
          {state.status === 'ready' && files.length > 0 && group !== null && (
            <FileChanges
              set={group.set}
              focusFile={changesFocus}
              resetKey={`${group.id}|${focusVisit ?? ''}|${changesFocus ?? ''}`}
              readFile={readFile}
              review={state.kind === 'session' ? reviewFor(null) : null}
            />
          )}
        </>
      )}
      {reviewSession !== null && (
        <ReviewBar session={reviewSession} comments={comments} onShow={showComment} />
      )}
    </aside>
  )
}
