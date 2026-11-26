import { useMemo, useRef, useState } from 'react'
import type { PointerEvent } from 'react'
import { RefreshIcon } from '../components/icons.tsx'
import { FileChanges } from '../components/FileChanges.tsx'
import {
  baseName,
  groupTotals,
  pathMatches,
  sinceLabel,
  type ChangesBase,
} from '../domain/changes.ts'
import { parseUnifiedDiff } from '../domain/unified-diff.ts'
import type { ChangesTab } from '../state/state.ts'
import type { CommitListState, CommitViewState } from '../state/useCommits.ts'
import type { ChangeGroup, ChangesState } from '../state/useChanges.ts'
import { GitTab } from './GitTab.tsx'
import { ActivityTab } from './ActivityTab.tsx'
import type { ActionKind } from '../domain/activity.ts'
import { FolderBar, type FolderBarProps } from './FolderBar.tsx'
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

// How a file of a group that is new is read: its patch between the group's two snapshots, or from
// its snapshot to the working tree now.
function fileReader(origin: ChangeGroup['origin']): (path: string) => Promise<FileDiff | null> {
  return (path) =>
    (origin.after === null
      ? transport.diffChanges(origin.folder, origin.before, path)
      : transport.diffChanges(origin.folder, origin.before, path, origin.after)
    ).then((answer) => parseUnifiedDiff(answer.patch)[0] ?? null)
}

// One repository's changes when several are shown: a heading with its folder's name and its totals,
// which opens and shuts the list below it.
function RepositoryGroup({
  group,
  focusFile,
  review,
}: {
  group: ChangeGroup
  focusFile: string | null
  review: DiffReview | null
}) {
  const [open, setOpen] = useState(true)
  const readFile = useMemo(() => fileReader(group.origin), [group.origin])
  const totals = groupTotals(group.set)
  return (
    <section className="changes-repository" aria-label={group.name}>
      <button
        className="changes-folder"
        aria-expanded={open}
        title={group.folder}
        onClick={() => setOpen((before) => !before)}
      >
        <span aria-hidden="true">{open ? '▾' : '▸'}</span> <strong>{group.name}</strong>{' '}
        <span className="muted small">
          {totals.files} {totals.files === 1 ? 'file' : 'files'}
        </span>{' '}
        <span className="changes-added">+{totals.added}</span>{' '}
        <span className="changes-removed">−{totals.removed}</span>
      </button>
      {open && totals.files > 0 && (
        <FileChanges
          set={group.set}
          focusFile={focusFile}
          resetKey={`${group.id}|${focusFile ?? ''}`}
          readFile={readFile}
          review={review}
        />
      )}
    </section>
  )
}

// The changes of what is being looked at, one group for each repository: a list of the files, and
// the diff of the one chosen. A file that is new is a row that is opened to be read. A terminal
// session also has a Git tab with the commits of its branch.
export function ChangesSidebar({
  state,
  onRefresh,
  live,
  focusFile,
  onBase,
  git,
  comments: reviewSession,
  folders,
  activity,
}: {
  state: ChangesState
  onRefresh: () => void
  // A step of the run is running: its changes are asked for after each tool call, and on Refresh.
  live: boolean
  // The file an activity asked for, by the whole path it names it with.
  focusFile: string | null
  // What a session's changes are to be against was chosen.
  onBase: (base: ChangesBase) => void
  // The Git tab of a terminal session; none on a run's page, which has its changes only.
  git: SessionGit | null
  // The terminal session whose diffs can be commented on and sent to its agent; none for a run.
  comments: string | null
  // The folder bar: the folder the changes are of and the repositories added to it.
  folders: FolderBarProps | null
  // The Activity tab of a terminal session: the kinds of action it shows, and showing a file the
  // conversation changed; none on a run's page.
  activity: SessionActivity | null
}) {
  const [width, setWidth] = useState(readWidth)
  const dragging = useRef(false)

  const groups: ChangeGroup[] = state.status === 'ready' ? state.groups : []
  const single = groups.length === 1 ? groups[0] : undefined
  const files = groups.flatMap((g) => g.set.files)
  const singleOrigin = single?.origin
  const readFile = useMemo(
    () => (singleOrigin === undefined ? null : fileReader(singleOrigin)),
    [singleOrigin],
  )

  const onGit = git !== null && git.tab === 'git'
  const onActivity = git !== null && git.tab === 'activity' && activity !== null
  const comments = useReview(reviewSession)
  // The file of a comment chosen in the review bar, shown in the tab it was written in.
  const [shown, setShown] = useState<{ path: string; commit: string | null } | null>(null)
  // With several repositories shown, a comment in the Changes tab names its repository, and each
  // group marks only the lines of its own comments.
  const reviewFor = (commit: string | null, repository: string | null = null): DiffReview | null =>
    reviewSession === null
      ? null
      : {
          commit,
          comments: comments.filter((c) => (c.repository ?? null) === repository),
          onComment: (comment) =>
            addComment(reviewSession, repository === null ? comment : { ...comment, repository }),
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
      {folders !== null && !onActivity && <FolderBar {...folders} />}
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
          {state.status === 'ready' && state.gone && (
            <p className="panel-empty" role="status">
              The snapshots of this run are gone.
            </p>
          )}
          {state.status === 'ready' && state.kind === 'run' && state.live && (
            <p className="panel-empty" role="status">
              Shown live: this run has no end snapshot.
            </p>
          )}
          {state.status === 'ready' && files.length === 0 && !state.gone && (
            <p className="panel-empty">
              {state.kind === 'run'
                ? 'This run has changed nothing.'
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
          {state.status === 'ready' && files.length > 0 && single !== undefined && (
            <FileChanges
              set={single.set}
              focusFile={changesFocus}
              resetKey={`${single.id}|${changesFocus ?? ''}`}
              readFile={readFile}
              review={reviewFor(null)}
            />
          )}
          {state.status === 'ready' &&
            files.length > 0 &&
            groups.length > 1 &&
            groups.map((g) => (
              <RepositoryGroup
                key={g.id}
                group={g}
                focusFile={changesFocus}
                review={reviewFor(null, g.name)}
              />
            ))}
        </>
      )}
      {reviewSession !== null && (
        <ReviewBar session={reviewSession} comments={comments} onShow={showComment} />
      )}
    </aside>
  )
}
