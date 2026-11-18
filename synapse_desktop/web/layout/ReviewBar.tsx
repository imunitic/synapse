// The review a terminal session has in progress, at the bottom of the Changes sidebar: how many
// comments, and sending them to the agent as one prompt, pasted into the session's terminal and
// submitted. Where no harness runs in the session the review is copied instead, since a shell
// would run the lines as commands.

import { useEffect, useState } from 'react'
import { MAX_INPUT_BYTES } from '../../shared/terminal.ts'
import { composeReview, placeOf, type ReviewComment } from '../domain/review.ts'
import {
  clearReview,
  editComment,
  onReviewChange,
  removeComment,
  reviewOf,
} from '../state/reviews.ts'
import { onTerminalInputChange, terminalInput } from '../state/terminal-input.ts'

// What bracketed paste wraps the text in, which counts against the input limit too.
const PASTE_MARKS = 12

// The comments of a session's review, read again whenever one changes.
export function useReview(session: string | null): ReviewComment[] {
  const [, setTick] = useState(0)
  useEffect(() => onReviewChange(() => setTick((n) => n + 1)), [])
  return session === null ? [] : reviewOf(session)
}

// Whether a harness runs in the session's terminal, and whether that terminal is on the page.
function useHarness(session: string): { present: boolean; harness: boolean } {
  const [, setTick] = useState(0)
  useEffect(() => onTerminalInputChange(() => setTick((n) => n + 1)), [])
  const input = terminalInput(session)
  return { present: input !== null, harness: input?.harness ?? false }
}

function CommentItem({
  session,
  comment,
  onShow,
}: {
  session: string
  comment: ReviewComment
  onShow: (comment: ReviewComment) => void
}) {
  const [editing, setEditing] = useState<string | null>(null)
  return (
    <li className="review-item">
      <button className="link small mono" onClick={() => onShow(comment)}>
        {comment.commit !== null && `${comment.commit.slice(0, 7)} · `}
        {placeOf(comment)}
      </button>
      {editing === null ? (
        <p className="review-text">{comment.text}</p>
      ) : (
        <textarea
          className="diff-comment-text"
          aria-label="Comment"
          value={editing}
          rows={3}
          onChange={(event) => setEditing(event.target.value)}
        />
      )}
      <span className="diff-comment-actions">
        {editing === null ? (
          <>
            <button className="link small" onClick={() => setEditing(comment.text)}>
              Edit
            </button>
            <button className="link small" onClick={() => removeComment(session, comment.id)}>
              Remove
            </button>
          </>
        ) : (
          <>
            <button
              className="link small"
              disabled={editing.trim() === ''}
              onClick={() => {
                editComment(session, comment.id, editing.trim())
                setEditing(null)
              }}
            >
              Save
            </button>
            <button className="link small" onClick={() => setEditing(null)}>
              Cancel
            </button>
          </>
        )}
      </span>
    </li>
  )
}

export function ReviewBar({
  session,
  comments,
  onShow,
}: {
  session: string
  comments: readonly ReviewComment[]
  // A comment's file is shown in the tab, and commit, it was written on.
  onShow: (comment: ReviewComment) => void
}) {
  const { present, harness } = useHarness(session)
  const [open, setOpen] = useState(false)
  const [said, setSaid] = useState<string | null>(null)
  const text = composeReview(comments)
  const bytes = new TextEncoder().encode(text).length + PASTE_MARKS
  const tooLarge = bytes > MAX_INPUT_BYTES

  function send() {
    const input = terminalInput(session)
    if (input === null) {
      setSaid('The terminal of this session is not open.')
      return
    }
    if (tooLarge) {
      setSaid('The review is too large to paste in one go: copy it instead.')
      return
    }
    input.send(text)
    clearReview(session)
    setOpen(false)
    setSaid(input.submits ? null : 'Pasted into the terminal: press Enter there to send it.')
  }

  function copy() {
    navigator.clipboard
      .writeText(text)
      .then(() => setSaid('Copied.'))
      .catch(() => setSaid('Could not copy the review.'))
  }

  // Nothing to show without comments, unless what was last done with them is still to be said.
  if (comments.length === 0 && said === null) return null
  return (
    <section className="review-bar" aria-label="Review">
      {comments.length > 0 && (
        <div className="review-row">
          <button className="link small" aria-expanded={open} onClick={() => setOpen(!open)}>
            {comments.length} {comments.length === 1 ? 'comment' : 'comments'}
          </button>
          <span className="review-actions">
            {harness && present && (
              <button className="primary small" disabled={tooLarge} onClick={send}>
                Send to agent
              </button>
            )}
            <button className="secondary small" onClick={copy}>
              Copy
            </button>
            <button className="link small" onClick={() => clearReview(session)}>
              Discard
            </button>
          </span>
        </div>
      )}
      {comments.length > 0 && !present && (
        <p className="muted small review-note">
          The terminal of this session is not open, so the review can only be copied.
        </p>
      )}
      {comments.length > 0 && present && !harness && (
        <p className="muted small review-note">
          No harness runs in this session, so the review is copied, not sent.
        </p>
      )}
      {comments.length > 0 && tooLarge && harness && (
        <p className="muted small review-note">
          The review is too large to paste in one go: copy it instead.
        </p>
      )}
      {said !== null && (
        <p className="muted small review-note" role="status">
          {said}
        </p>
      )}
      {open && (
        <ol className="review-list">
          {comments.map((c) => (
            <CommentItem key={c.id} session={session} comment={c} onShow={onShow} />
          ))}
        </ol>
      )}
    </section>
  )
}
