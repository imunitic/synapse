// The files of a set of changes and the diff of the one chosen: the list the Changes sidebar shows,
// in its Changes tab for a session or a run and in its Git tab for a commit. A new file is a row that
// is opened to be read, through `readFile`; a run has every file's content in its patch already.

import { Fragment, useEffect, useRef, useState, type ReactNode } from 'react'
import {
  baseName,
  groupByFolder,
  pathMatches,
  type ChangedFile,
  type ChangeSet,
} from '../domain/changes.ts'
import { quoteOf, type ReviewComment } from '../domain/review.ts'
import type { FileDiff, PatchLine } from '../domain/unified-diff.ts'

// A file with more lines than this shows the first of them, so that the page stays quick.
const MOST_LINES = 3000

const LETTERS = { modified: 'M', added: 'A', deleted: 'D', renamed: 'R' } as const

// The lines added and removed, as the rows of a file or a commit show them; none for a binary file.
export function Counts({ added, removed }: { added: number | null; removed: number | null }) {
  if (added === null && removed === null) return <span className="muted small">binary</span>
  return (
    <span className="changes-counts">
      {added !== null && added > 0 && <span className="changes-added">+{added}</span>}
      {removed !== null && removed > 0 && <span className="changes-removed">−{removed}</span>}
    </span>
  )
}

function FileRow({
  file,
  selected,
  onSelect,
}: {
  file: ChangedFile
  selected: boolean
  onSelect: () => void
}) {
  return (
    <button
      className="changes-file"
      aria-current={selected ? 'true' : undefined}
      onClick={onSelect}
      title={file.oldPath === null ? file.path : `${file.oldPath} → ${file.path}`}
    >
      <span className="changes-status" data-status={file.status} aria-label={file.status}>
        {LETTERS[file.status]}
      </span>
      <span className="changes-name">{baseName(file.path)}</span>
      <Counts added={file.added} removed={file.removed} />
    </button>
  )
}

// What a diff can be reviewed with: the comments of the session's review, to mark their lines, and
// how a new one is added. None on a run's page, where nothing can be chosen.
export interface DiffReview {
  // The commit the diff is of, in the Git tab; none in the Changes tab.
  commit: string | null
  comments: readonly ReviewComment[]
  onComment: (comment: Omit<ReviewComment, 'id'>) => void
}

// Which file's numbers a line is placed by: a removed line has only the old one.
function sideOf(line: PatchLine): 'new' | 'old' {
  return line.kind === 'remove' ? 'old' : 'new'
}

function numberOf(line: PatchLine): number | null {
  return sideOf(line) === 'old' ? line.oldNumber : line.newNumber
}

// The lines chosen in a hunk: from the line first clicked to the one shift-clicked, those on the
// side of the first.
interface Choice {
  hunk: number
  anchor: number
  other: number
}

function chosenLines(lines: readonly PatchLine[], choice: Choice): PatchLine[] {
  const anchor = lines[choice.anchor]
  if (anchor === undefined) return []
  const from = Math.min(choice.anchor, choice.other)
  const to = Math.max(choice.anchor, choice.other)
  return lines
    .slice(from, to + 1)
    .filter((line) => line.kind !== 'note' && sideOf(line) === sideOf(anchor))
}

function Lines({
  lines,
  chosen,
  commented,
  onChoose,
  after,
  box,
}: {
  lines: PatchLine[]
  chosen: ReadonlySet<PatchLine>
  commented: (line: PatchLine) => boolean
  // A line's number was clicked, with shift or not; none when lines cannot be chosen.
  onChoose: ((index: number, extend: boolean) => void) | null
  // The row the box goes under: the last chosen line, so that it shows where the person is looking.
  after: number | null
  box: ReactNode
}) {
  return (
    <>
      {lines.map((line, index) => {
        const number = numberOf(line)
        const own = (n: number | null, side: 'new' | 'old') =>
          onChoose !== null && line.kind !== 'note' && n !== null && sideOf(line) === side ? (
            <button
              className="diff-no diff-pick"
              aria-label={`Choose line ${n}`}
              onClick={(event) => onChoose(index, event.shiftKey)}
            >
              {n}
            </button>
          ) : (
            <span className="diff-no">{n ?? ''}</span>
          )
        return (
          <Fragment key={index}>
            <div
              className="diff-row"
              data-kind={line.kind}
              data-chosen={chosen.has(line) || undefined}
              data-commented={(number !== null && commented(line)) || undefined}
            >
              {own(line.oldNumber, 'old')}
              {own(line.newNumber, 'new')}
              <span className="diff-sign">
                {line.kind === 'add' ? '+' : line.kind === 'remove' ? '−' : ''}
              </span>
              <span className="diff-text">{line.text}</span>
            </div>
            {after === index && box}
          </Fragment>
        )
      })}
    </>
  )
}

// Under the chosen lines: what they are, and the comment on them, written at once. The draft is
// kept by the diff, so that extending the choice, which moves the box, does not lose it.
function CommentBox({
  label,
  text,
  onText,
  onSave,
  onCancel,
}: {
  label: string
  text: string
  onText: (text: string) => void
  onSave: (text: string) => void
  onCancel: () => void
}) {
  const own = useRef<HTMLDivElement>(null)
  // It shows under the chosen lines; brought into view in case they are at the bottom.
  useEffect(() => {
    own.current?.scrollIntoView({ block: 'nearest' })
  }, [])
  const save = () => {
    if (text.trim() !== '') onSave(text.trim())
  }
  return (
    <div ref={own} className="diff-comment" role="group" aria-label="Comment on the chosen lines">
      <span className="muted small">{label}</span>
      <textarea
        className="diff-comment-text"
        aria-label="Comment"
        value={text}
        autoFocus
        rows={3}
        onChange={(event) => onText(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Escape') onCancel()
          else if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
            event.preventDefault()
            save()
          }
        }}
      />
      <span className="diff-comment-actions">
        <button className="primary small" disabled={text.trim() === ''} onClick={save}>
          Save
        </button>
        <button className="secondary small" onClick={onCancel}>
          Cancel
        </button>
      </span>
    </div>
  )
}

function DiffView({
  file,
  diff,
  review,
}: {
  file: ChangedFile
  diff: FileDiff | null
  review: DiffReview | null
}) {
  const [choice, setChoice] = useState<Choice | null>(null)
  // The comment being written on the chosen lines; a new choice starts it again, extending keeps it.
  const [draft, setDraft] = useState('')
  const clear = () => {
    setChoice(null)
    setDraft('')
  }
  let shown = 0
  let cut = 0
  const mine = (review?.comments ?? []).filter(
    (c) => c.path === file.path && c.commit === (review?.commit ?? null),
  )
  const commented = (line: PatchLine) => {
    const n = numberOf(line)
    return n !== null && mine.some((c) => c.side === sideOf(line) && n >= c.start && n <= c.end)
  }
  return (
    <section className="changes-diff" aria-label={`Changes in ${file.path}`}>
      <h3 className="changes-diff-title mono">
        {file.oldPath !== null && <span className="muted">{file.oldPath} → </span>}
        {file.path}
      </h3>
      {file.binary && <p className="muted small">A binary file: there are no lines to show.</p>}
      {!file.binary && diff === null && file.deferred && (
        <p className="muted small">Reading the file…</p>
      )}
      {diff?.notKept === true && (
        <p className="muted small">
          The content of this file was not kept: it was larger than the limit a run keeps.
        </p>
      )}
      {diff !== null && !file.binary && !diff.notKept && diff.hunks.length === 0 && (
        <p className="muted small">No lines changed.</p>
      )}
      {diff !== null &&
        diff.hunks.map((hunk, index) => {
          const room = Math.max(0, MOST_LINES - shown)
          const lines = hunk.lines.slice(0, room)
          shown += lines.length
          cut += hunk.lines.length - lines.length
          const here = choice !== null && choice.hunk === index
          const chosen = here ? chosenLines(lines, choice) : []
          const first = chosen[0]
          const last = chosen.at(-1)
          const start = first === undefined ? null : numberOf(first)
          const end = last === undefined ? null : numberOf(last)
          const box =
            review !== null && first !== undefined && start !== null && end !== null ? (
              <CommentBox
                key={`${index}-${start}-${end}`}
                label={`${chosen.length === 1 ? 'Line' : 'Lines'} ${start === end ? start : `${start}–${end}`}${sideOf(first) === 'old' ? ' (removed)' : ''} chosen`}
                text={draft}
                onText={setDraft}
                onCancel={clear}
                onSave={(text) => {
                  review.onComment({
                    path: file.path,
                    commit: review.commit,
                    side: sideOf(first),
                    start,
                    end,
                    ...quoteOf(chosen),
                    text,
                  })
                  clear()
                }}
              />
            ) : null
          return (
            <div key={index} className="diff-hunk">
              <div className="diff-header mono">{hunk.header}</div>
              <Lines
                lines={lines}
                chosen={new Set(chosen)}
                commented={commented}
                onChoose={
                  review === null
                    ? null
                    : (line, extend) => {
                        if (extend && here) {
                          setChoice({ ...choice, other: line })
                        } else {
                          setChoice({ hunk: index, anchor: line, other: line })
                          setDraft('')
                        }
                      }
                }
                after={here && box !== null ? Math.max(choice.anchor, choice.other) : null}
                box={box}
              />
            </div>
          )
        })}
      {cut > 0 && <p className="muted small">{cut} more lines are not shown.</p>}
    </section>
  )
}

export function FileChanges({
  set,
  focusFile,
  resetKey,
  readFile,
  review = null,
}: {
  set: ChangeSet
  // The file an activity asked for, by the whole path it names it with.
  focusFile: string | null
  // The row the person chose counts while this stays the same: it changes when what is shown does.
  resetKey: string
  // Reads a new file's whole patch when its row is chosen; null when the set has every file's.
  readFile: ((path: string) => Promise<FileDiff | null>) | null
  // How the diff is commented on; none where it cannot be.
  review?: DiffReview | null
}) {
  const [selection, setSelection] = useState<{ key: string; path: string } | null>(null)
  // The folders of the list that are shut.
  const [shut, setShut] = useState<ReadonlySet<string>>(new Set())
  const [opened, setOpened] = useState<{ path: string; diff: FileDiff | null } | null>(null)

  const files = set.files
  // A file that is new is read when it is chosen; the first of the others is shown at once.
  const picked = selection?.key === resetKey ? selection.path : null
  const named =
    focusFile === null ? null : (files.find((f) => pathMatches(focusFile, f.path))?.path ?? null)
  const current =
    files.find((f) => f.path === (picked ?? named)) ??
    files.find((f) => f.status !== 'added') ??
    null
  const currentPath = current?.path
  const mustRead =
    current !== null && current.deferred && readFile !== null && !set.diffs.has(current.path)

  // A new file's content is asked for when its row is chosen, and again as the changes are.
  useEffect(() => {
    if (readFile === null || currentPath === undefined || !mustRead) return
    let live = true
    readFile(currentPath)
      .then((diff) => {
        if (live) setOpened({ path: currentPath, diff })
      })
      .catch(() => undefined)
    return () => {
      live = false
    }
  }, [set, readFile, currentPath, mustRead])

  const added = files.reduce((sum, f) => sum + (f.added ?? 0), 0)
  const removed = files.reduce((sum, f) => sum + (f.removed ?? 0), 0)
  const diff =
    current === null
      ? null
      : (set.diffs.get(current.path) ??
        (mustRead && opened?.path === current.path ? opened.diff : null))

  return (
    <>
      <p className="changes-summary muted small">
        {files.length} {files.length === 1 ? 'file' : 'files'} changed{' '}
        <span className="changes-added">+{added}</span>{' '}
        <span className="changes-removed">−{removed}</span>
      </p>
      <div className="changes-list" role="group" aria-label="Changed files">
        {groupByFolder(files).map((folder) => (
          <div key={folder.folder} className="changes-group">
            {folder.folder !== '' && (
              <button
                className="changes-folder mono muted small"
                aria-expanded={!shut.has(folder.folder)}
                onClick={() =>
                  setShut((before) => {
                    const next = new Set(before)
                    if (!next.delete(folder.folder)) next.add(folder.folder)
                    return next
                  })
                }
              >
                <span aria-hidden="true">{shut.has(folder.folder) ? '▸' : '▾'}</span>{' '}
                {folder.folder}/
              </button>
            )}
            {!shut.has(folder.folder) &&
              folder.files.map((file) => (
                <FileRow
                  key={file.path}
                  file={file}
                  selected={file.path === current?.path}
                  onSelect={() => setSelection({ key: resetKey, path: file.path })}
                />
              ))}
          </div>
        ))}
      </div>
      {current !== null && (
        <DiffView key={current.path} file={current} diff={diff} review={review} />
      )}
    </>
  )
}
