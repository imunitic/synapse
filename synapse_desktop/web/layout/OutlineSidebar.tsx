import { useCallback, useRef, useState } from 'react'
import type { PointerEvent } from 'react'
import { isGraphNodePath } from '../domain/notes.ts'
import { commentCounts } from '../domain/note-review.ts'
import {
  duplicatePaths,
  noteOutline,
  outlineTree,
  type OutlineHeading,
  type OutlineNode,
  visibleTitle,
} from '../domain/outline.ts'
import { noteHeadings } from '../state/note-headings.ts'
import { useNoteReview } from '../state/note-reviews.ts'
import { useLoad } from '../state/useLoad.ts'
import { useWatch } from '../state/useWatch.ts'
import { transport } from '../transport/index.ts'
import { keepWidth, MAX_WIDTH, MIN_WIDTH, readWidth } from './ChangesSidebar.tsx'
import { NoteReviewBar } from './NoteReviewBar.tsx'

// The headings of a note, nested, in place of the Changes sidebar on a note's page: a heading is
// clicked to scroll the note to it, and on a note that is not a node of a code graph it can be
// commented on. The headings are those `synapse vault-doc-map` gives, read again when the vault
// changes. It shares its width with the Changes sidebar, and the note's review is at its bottom.
export function OutlineSidebar({ path }: { path: string }) {
  const [width, setWidth] = useState(readWidth)
  const dragging = useRef(false)
  const readOutline = useCallback(() => noteOutline(transport, path), [path])
  const outline = useLoad(readOutline)
  useWatch('vault', outline.reload)
  const comments = useNoteReview(path)
  const counts = commentCounts(comments)
  const commentable = !isGraphNodePath(path)

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

  // Sibling headings with the same title share a path, so the list is keyed by position too, and
  // such a path offers no comment (see `duplicatePaths`).
  const renderNodes = (nodes: readonly OutlineNode[], shared: ReadonlySet<string>) => (
    <ul className="outline-list">
      {nodes.map(({ heading, children }, index) => {
        const count = counts.get(heading.path) ?? 0
        const title = visibleTitle(heading.title)
        return (
          <li key={`${index}:${heading.path}`} className="outline-item">
            <div className="outline-row">
              <button
                className="outline-heading"
                title={heading.path}
                onClick={() => noteHeadings(path)?.scrollTo(heading.path)}
              >
                {title}
              </button>
              {count > 0 && (
                <span
                  className="outline-count"
                  aria-label={`${count} ${count === 1 ? 'comment' : 'comments'}`}
                >
                  {count}
                </span>
              )}
              {commentable && !shared.has(heading.path) && (
                <button
                  className="outline-comment"
                  aria-label={`Comment on ${title}`}
                  title="Comment on this section"
                  onClick={() => noteHeadings(path)?.comment(heading.path)}
                >
                  Comment
                </button>
              )}
            </div>
            {children.length > 0 && renderNodes(children, shared)}
          </li>
        )
      })}
    </ul>
  )

  const renderOutline = (headings: readonly OutlineHeading[]) =>
    renderNodes(outlineTree(headings), duplicatePaths(headings))

  return (
    <aside className="changes" aria-label="Outline" style={{ width }}>
      <div
        className="changes-resize"
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize the Outline sidebar"
        onPointerDown={startDrag}
        onPointerMove={drag}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
      />
      <div className="panel-header">
        <h2 className="panel-title">Outline</h2>
      </div>
      {outline.state.status === 'loading' && <p className="panel-empty">Reading the headings…</p>}
      {outline.state.status === 'failed' && (
        <p className="panel-empty" role="alert">
          {outline.state.error}
        </p>
      )}
      {outline.state.status === 'ready' && outline.state.data.length === 0 && (
        <p className="panel-empty">This note has no headings.</p>
      )}
      {outline.state.status === 'ready' && outline.state.data.length > 0 && (
        <nav className="outline" aria-label="Headings">
          {renderOutline(outline.state.data)}
        </nav>
      )}
      {commentable && (
        <NoteReviewBar
          path={path}
          comments={comments}
          outline={outline.state.status === 'ready' ? outline.state.data : null}
        />
      )}
    </aside>
  )
}
