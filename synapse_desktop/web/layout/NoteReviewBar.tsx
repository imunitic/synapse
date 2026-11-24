// The review of a vault note in progress, at the bottom of the Outline sidebar: how many comments,
// and sending them to an agent as one headless run that changes the note, the pencil's run, with
// its result card and undo on the page. The comments sent are removed only when the run changed
// the note, and comments written while it ran stay; when it failed they all stay, and the failure
// is said here.

import { useState } from 'react'
import { RunChoice, useRunChoice } from '../components/RunChoice.tsx'
import { WorkingLine } from '../components/WorkingLine.tsx'
import { activityOfRun, latestAction } from '../domain/note-run.ts'
import { composeNoteReview, orphaned, type NoteComment } from '../domain/note-review.ts'
import type { OutlineHeading } from '../domain/outline.ts'
import { startNoteEdit, stopNoteEdit, useNoteEdit } from '../state/note-edits.ts'
import { noteHeadings } from '../state/note-headings.ts'
import {
  clearNoteReview,
  editNoteComment,
  removeNoteComment,
  removeNoteComments,
} from '../state/note-reviews.ts'

function CommentItem({
  path,
  comment,
  gone,
}: {
  path: string
  comment: NoteComment
  // Whether the comment's section is no longer a heading of the note.
  gone: boolean
}) {
  const [editing, setEditing] = useState<string | null>(null)
  const section = comment.section
  return (
    <li className="review-item">
      {section === null ? (
        <span className="small muted">Whole note</span>
      ) : gone ? (
        <span className="small mono">
          {section} <span className="warn-line">(section no longer in the note)</span>
        </span>
      ) : (
        <button className="link small mono" onClick={() => noteHeadings(path)?.scrollTo(section)}>
          {section}
        </button>
      )}
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
            <button className="link small" onClick={() => removeNoteComment(path, comment.id)}>
              Remove
            </button>
          </>
        ) : (
          <>
            <button
              className="link small"
              disabled={editing.trim() === ''}
              onClick={() => {
                editNoteComment(path, comment.id, editing.trim())
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

export function NoteReviewBar({
  path,
  comments,
  outline,
}: {
  path: string
  comments: readonly NoteComment[]
  // The note's headings as the doc-map gives them, or null while they are not read.
  outline: readonly OutlineHeading[] | null
}) {
  const { harness, model, chooseHarness, chooseModel } = useRunChoice()
  const { working, failure, startedAt, harness: runHarness, stopping, lines } = useNoteEdit(path)
  const [open, setOpen] = useState(false)
  const gone = outline === null ? new Set<string>() : orphaned(comments, outline)

  function send() {
    if (outline === null) return
    const prompt = composeNoteReview(path, comments, outline)
    const sent = new Set(comments.map((c) => c.id))
    startNoteEdit(path, { path, prompt, harness, ...(model === null ? {} : { model }) }, (ok) => {
      if (!ok) return
      removeNoteComments(path, sent)
      setOpen(false)
    })
  }

  if (comments.length === 0) return null
  return (
    <section className="review-bar" aria-label="Note review">
      <div className="review-row">
        <button className="link small" aria-expanded={open} onClick={() => setOpen(!open)}>
          {comments.length} {comments.length === 1 ? 'comment' : 'comments'}
        </button>
        <span className="review-actions">
          <button className="primary small" disabled={working || outline === null} onClick={send}>
            {working ? 'Sending…' : 'Send to agent'}
          </button>
          <button className="link small" disabled={working} onClick={() => clearNoteReview(path)}>
            Discard
          </button>
        </span>
      </div>
      {working && startedAt !== null && (
        <WorkingLine
          harness={runHarness ?? harness}
          startedAt={startedAt}
          doing="changing the note"
          action={latestAction(activityOfRun(lines))}
          stopping={stopping}
          onStop={() => stopNoteEdit(path)}
        />
      )}
      {!working && failure !== null && (
        <p className="error small review-note" role="alert">
          {failure}
        </p>
      )}
      {outline === null && (
        <p className="muted small review-note">
          The headings of the note are not read, so the review cannot be sent yet.
        </p>
      )}
      {open && (
        <>
          <ol className="review-list">
            {comments.map((c) => (
              <CommentItem key={c.id} path={path} comment={c} gone={gone.has(c.id)} />
            ))}
          </ol>
          <RunChoice
            harness={harness}
            model={model}
            onHarness={chooseHarness}
            onModel={chooseModel}
            disabled={working}
          />
        </>
      )}
    </section>
  )
}
