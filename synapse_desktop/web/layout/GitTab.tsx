// The Git tab of the Changes sidebar, for a terminal session: the commits of the branch its harness
// is on, newest first, and what one of them changed. Read-only: committing, pushing and pulling are
// left to the agent in the terminal.

import type { Commit } from '../../shared/changes.ts'
import { Counts, FileChanges, type DiffReview } from '../components/FileChanges.tsx'
import { timeAgo } from '../domain/format.ts'
import type { FileDiff } from '../domain/unified-diff.ts'
import type { CommitListState, CommitViewState } from '../state/useCommits.ts'

// A commit by the first seven digits of its hash, as git shows it.
function short(hash: string): string {
  return hash.slice(0, 7)
}

function CommitRow({ commit, now, onOpen }: { commit: Commit; now: Date; onOpen: () => void }) {
  return (
    <button className="git-commit" onClick={onOpen} title={commit.hash}>
      <span className="git-commit-text">
        <span className="git-commit-subject">
          <span className="mono muted">{short(commit.hash)}</span> {commit.subject}
        </span>
        <span className="git-commit-meta muted small">
          {commit.author} · {timeAgo(commit.time, now)}
        </span>
      </span>
      <Counts added={commit.added} removed={commit.removed} />
    </button>
  )
}

export function GitTab({
  list,
  view,
  commit,
  readFile,
  onCommit,
  onLoadMore,
  review,
  focusFile,
}: {
  list: CommitListState
  view: CommitViewState
  // The commit shown, by its hash; none shows the list.
  commit: string | null
  readFile: ((path: string) => Promise<FileDiff | null>) | null
  onCommit: (commit: string | null) => void
  onLoadMore: () => void
  // How the shown commit's diff is commented on, for the session's review.
  review: DiffReview | null
  // A file of the shown commit to show, as a comment in the review asked.
  focusFile: string | null
}) {
  const now = new Date()

  if (commit !== null) {
    // The heading says what the list said of it, or its hash when the list does not have it.
    const listed = list.status === 'ready' ? list.commits.find((c) => c.hash === commit) : undefined
    return (
      <>
        <div className="git-heading">
          <button className="link small" onClick={() => onCommit(null)}>
            ← Commits
          </button>
          <h3 className="git-title">
            <span className="mono">{short(commit)}</span>
            {listed !== undefined && (
              <>
                {' · '}
                {listed.subject}
                <span className="muted"> · {timeAgo(listed.time, now)}</span>
              </>
            )}
          </h3>
        </div>
        {view.status === 'loading' && <p className="panel-empty">Reading the commit…</p>}
        {view.status === 'failed' && (
          <p className="panel-empty" role="alert">
            {view.error}
          </p>
        )}
        {view.status === 'ready' && view.set.files.length === 0 && (
          <p className="panel-empty">This commit changed no files.</p>
        )}
        {view.status === 'ready' && view.set.files.length > 0 && (
          <FileChanges
            set={view.set}
            focusFile={focusFile}
            resetKey={`${view.hash}|${focusFile ?? ''}`}
            readFile={readFile}
            review={review}
          />
        )}
      </>
    )
  }

  return (
    <>
      {list.status === 'waiting' && (
        <p className="panel-empty">The starting point of this session is not taken yet.</p>
      )}
      {list.status === 'loading' && <p className="panel-empty">Reading the commits…</p>}
      {list.status === 'no-repository' && (
        <p className="panel-empty">
          This folder is not in a git repository, so there are no commits to show.
        </p>
      )}
      {list.status === 'failed' && (
        <p className="panel-empty" role="alert">
          {list.error}
        </p>
      )}
      {list.status === 'ready' && list.commits.length === 0 && (
        <p className="panel-empty">No commits yet.</p>
      )}
      {list.status === 'ready' && list.commits.length > 0 && (
        <div className="git-commits" role="group" aria-label="Commits">
          {list.commits.map((c) => (
            <CommitRow key={c.hash} commit={c} now={now} onOpen={() => onCommit(c.hash)} />
          ))}
          {list.more && (
            <button
              className="secondary small git-more"
              disabled={list.loadingMore}
              onClick={onLoadMore}
            >
              {list.loadingMore ? 'Loading…' : 'Load more'}
            </button>
          )}
        </div>
      )}
    </>
  )
}
