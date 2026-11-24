import { TaskStatus } from '../components/TaskStatus.tsx'
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
} from 'react'
import Markdown, { type Components, type ExtraProps } from 'react-markdown'
import remarkGfm from 'remark-gfm'
import {
  isGraphNodePath,
  linkifyWikilinks,
  listNotes,
  nameIndex,
  noteBacklinks,
  noteLinks,
  readNote,
  resolveLink,
  titleOf,
  wikilinkTarget,
  withoutTitleHeading,
} from '../domain/notes.ts'
import { noteSummary } from '../domain/note-summary.ts'
import { duplicatePaths, noteOutline, pairHeadings } from '../domain/outline.ts'
import { recordOpened } from '../domain/recent.ts'
import { isWide, setWide } from '../domain/wide-notes.ts'
import { transport } from '../transport/index.ts'
import { RefreshIcon } from '../components/icons.tsx'
import { EditNote } from '../components/EditNote.tsx'
import { WideSwitch } from '../components/WideSwitch.tsx'
import type { Page } from '../state/state.ts'
import { addNoteComment } from '../state/note-reviews.ts'
import { registerNoteHeadings } from '../state/note-headings.ts'
import { useLoad } from '../state/useLoad.ts'
import { useWatch } from '../state/useWatch.ts'

// A link of a note is a web link, a mail address, a link to a note or a place
// in the page; nothing else, since a note is text someone wrote.
function safeUrl(url: string): string {
  return /^(https?:|mailto:|wikilink:|#)/i.test(url) ? url : ''
}

function Property({ name, value }: { name: string; value: unknown }) {
  let shown: ReactNode
  if (Array.isArray(value)) {
    shown = (
      <span className="chips">
        {value.map((item, i) => (
          <span key={i} className="chip-plain">
            {String(item)}
          </span>
        ))}
      </span>
    )
  } else if (typeof value === 'object' && value !== null) {
    shown = <span className="mono small">{JSON.stringify(value)}</span>
  } else {
    shown = <span>{String(value ?? '')}</span>
  }
  return (
    <>
      <dt className="muted small">{name}</dt>
      <dd>{shown}</dd>
    </>
  )
}

// A box to write a comment in: Save keeps it in the note's review, Cancel or Esc drops it, and
// Cmd or Ctrl+Enter saves.
function CommentBox({
  label,
  onSave,
  onCancel,
}: {
  label: string
  onSave: (text: string) => void
  onCancel: () => void
}) {
  const [text, setText] = useState('')
  const empty = text.trim() === ''

  function handleKey(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key === 'Escape') {
      event.preventDefault()
      onCancel()
    } else if (event.key === 'Enter' && (event.metaKey || event.ctrlKey) && !empty) {
      event.preventDefault()
      onSave(text)
    }
  }

  return (
    <section className="card note-comment-box" aria-label={label}>
      <textarea
        rows={3}
        autoFocus
        aria-label="Comment"
        value={text}
        onChange={(event) => setText(event.target.value)}
        onKeyDown={handleKey}
      />
      <div className="row">
        <button className="primary" disabled={empty} onClick={() => onSave(text)}>
          Save
        </button>
        <button className="secondary" onClick={onCancel}>
          Cancel
        </button>
      </div>
    </section>
  )
}

// What the headings of the note body need from the page: the doc-map path each rendered heading
// is paired with (by its offset in the markdown), the paths several headings share (offered no
// comment, see `duplicatePaths`), whether comments are offered, which heading's
// comment box is open, and how to open, save and close it.
interface BodyHeadings {
  paths: ReadonlyMap<number, string | null>
  shared: ReadonlySet<string>
  commentable: boolean
  commenting: string | undefined
  comment: (section: string) => void
  save: (section: string, text: string) => void
  cancel: () => void
}

const BodyHeadingsContext = createContext<BodyHeadings | null>(null)

// A heading of the note body, with a Comment button when it is paired with a doc-map path.
function BodyHeading({
  level,
  node,
  children,
}: {
  level: 1 | 2 | 3 | 4 | 5 | 6
  children?: ReactNode
} & ExtraProps) {
  const headings = useContext(BodyHeadingsContext)
  const offset = node?.position?.start.offset
  const section = offset === undefined ? null : (headings?.paths.get(offset) ?? null)
  const Tag = `h${level}` as const
  return (
    <>
      <div className="note-heading" data-section={section ?? undefined}>
        <Tag data-heading={offset}>{children}</Tag>
        {headings !== null &&
          headings.commentable &&
          section !== null &&
          !headings.shared.has(section) && (
            <button
              className="secondary note-heading-comment"
              title={`Comment on ${section}`}
              onClick={() => headings.comment(section)}
            >
              Comment
            </button>
          )}
      </div>
      {headings !== null && section !== null && headings.commenting === section && (
        <CommentBox
          label={`Comment on ${section}`}
          onSave={(text) => headings.save(section, text)}
          onCancel={headings.cancel}
        />
      )}
    </>
  )
}

const HEADING_COMPONENTS: Components = {
  h1: (props) => <BodyHeading level={1} {...props} />,
  h2: (props) => <BodyHeading level={2} {...props} />,
  h3: (props) => <BodyHeading level={3} {...props} />,
  h4: (props) => <BodyHeading level={4} {...props} />,
  h5: (props) => <BodyHeading level={5} {...props} />,
  h6: (props) => <BodyHeading level={6} {...props} />,
}

function samePaths(a: ReadonlyMap<number, string | null>, b: ReadonlyMap<number, string | null>) {
  if (a.size !== b.size) return false
  for (const [key, value] of a) if (b.get(key) !== value) return false
  return true
}

// A note of the vault: its properties, its text, and the notes it links to and
// is linked from.
export function NotePage({ path, onOpen }: { path: string; onOpen: (page: Page) => void }) {
  const read = useCallback(() => readNote(transport, path), [path])
  const readLinks = useCallback(() => noteLinks(transport, path), [path])
  const readBacklinks = useCallback(() => noteBacklinks(transport, path), [path])
  const readAll = useCallback(() => listNotes(transport), [])
  const readOutline = useCallback(() => noteOutline(transport, path), [path])
  const note = useLoad(read)
  const outline = useLoad(readOutline)
  // A note that was read is one that was opened, which the home page offers again.
  useEffect(() => {
    if (note.state.status === 'ready') recordOpened(path)
  }, [note.state.status, path])
  const links = useLoad(readLinks)
  const backlinks = useLoad(readBacklinks)
  const all = useLoad(readAll)
  // The choice is read from the browser on every render, so the next note opened in this
  // tab shows its own choice; a change makes the page render again to show it.
  const [, rerender] = useReducer((n: number) => n + 1, 0)
  const wide = isWide(path)
  const wideSwitch = (
    <WideSwitch
      wide={wide}
      onChange={(next) => {
        setWide(path, next)
        rerender()
      }}
    />
  )

  const index = useMemo(
    () => nameIndex(all.state.status === 'ready' ? all.state.data : []),
    [all.state],
  )
  const linked = useMemo(
    () => new Set(links.state.status === 'ready' ? links.state.data : []),
    [links.state],
  )
  const body = useMemo(
    () =>
      note.state.status === 'ready'
        ? linkifyWikilinks(
            withoutTitleHeading(note.state.data.body, [
              note.state.data.title,
              titleOf(note.state.data.path),
            ]),
          )
        : '',
    [note.state],
  )

  // The note, the notes it links to and from, and the names links are matched with are read again
  // when the vault changes, since a note can be changed by another program, and on request.
  function readAgain() {
    note.reload()
    outline.reload()
    links.reload()
    backlinks.reload()
    all.reload()
  }
  useWatch('vault', readAgain)

  function readChanged() {
    note.reload()
    outline.reload()
  }

  // The rendered headings are paired with the doc-map's paths by their titles in order, after
  // they are on the page; a heading with no path offers no comment.
  const article = useRef<HTMLElement>(null)
  const [paths, setPaths] = useState<ReadonlyMap<number, string | null>>(new Map())
  useLayoutEffect(() => {
    const elements = [...(article.current?.querySelectorAll<HTMLElement>('[data-heading]') ?? [])]
    const headings = outline.state.status === 'ready' ? outline.state.data : []
    const paired = pairHeadings(
      headings,
      elements.map((element) => element.textContent ?? ''),
    )
    const next = new Map(
      elements.map((element, i) => [Number(element.dataset.heading), paired[i] ?? null]),
    )
    setPaths((current) => (samePaths(current, next) ? current : next))
  }, [body, outline.state])

  // The open comment box: a heading's path, undefined for none.
  const [commenting, setCommenting] = useState<string | undefined>(undefined)
  useEffect(() => setCommenting(undefined), [path])
  const commentable = !isGraphNodePath(path)
  const shared = useMemo(
    () => duplicatePaths(outline.state.status === 'ready' ? outline.state.data : []),
    [outline.state],
  )
  // A section the outline offers but no body heading is paired with (the H1 the page strips, a
  // heading the pairing could not match) gets its comment box at the top, and scrolling to it goes
  // to the top of the page.
  const page = useRef<HTMLDivElement>(null)
  const unpaired =
    commenting !== undefined && ![...paths.values()].includes(commenting) ? commenting : null

  const bodyHeadings = useMemo<BodyHeadings>(
    () => ({
      paths,
      shared,
      commentable,
      commenting,
      comment: setCommenting,
      save: (section, text) => {
        addNoteComment(path, { section, text })
        setCommenting(undefined)
      },
      cancel: () => setCommenting(undefined),
    }),
    [paths, shared, commentable, commenting, path],
  )

  // The Outline sidebar reaches the headings through the registry while this page shows the note.
  useEffect(
    () =>
      registerNoteHeadings(path, {
        scrollTo: (section) => {
          const element = [
            ...(article.current?.querySelectorAll<HTMLElement>('[data-section]') ?? []),
          ].find((candidate) => candidate.dataset.section === section)
          ;(element ?? page.current)?.scrollIntoView({ block: 'start' })
        },
        comment: (section) => {
          if (commentable && !shared.has(section)) setCommenting(section)
        },
      }),
    [path, commentable, shared],
  )

  if (note.state.status === 'loading') return <p className="muted">Loading…</p>
  if (note.state.status === 'failed') {
    return <p role="alert">Could not read the note: {note.state.error}</p>
  }
  const { title, frontmatter } = note.state.data
  const properties = Object.entries(frontmatter ?? {}).filter(([key]) => key !== 'title')
  const summary = noteSummary(frontmatter, new Date())
  // A task note has a task id and a status, which a person can set to DONE from here.
  const taskStatus =
    frontmatter !== null && 'task_id' in frontmatter && typeof frontmatter.status === 'string'
      ? frontmatter.status
      : null

  return (
    <div ref={page} className={wide ? 'page note wide' : 'page note'}>
      <p className="eyebrow">
        {path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : 'Vault'}
      </p>
      {isGraphNodePath(path) ? (
        <div className="note-head">
          <h1 className="page-title">{title}</h1>
          <div className="note-tools">
            {wideSwitch}
            <button
              className="icon-button"
              aria-label="Read the note again"
              title="Read the note again"
              onClick={readAgain}
            >
              <RefreshIcon />
            </button>
          </div>
        </div>
      ) : (
        <EditNote
          path={path}
          title={title}
          onChanged={readChanged}
          onRefresh={readAgain}
          tools={
            <>
              {wideSwitch}
              {taskStatus !== null && (
                <TaskStatus path={path} status={taskStatus} onChanged={readAgain} />
              )}
            </>
          }
        />
      )}
      {commentable && unpaired !== null && (
        <CommentBox
          label={`Comment on ${unpaired}`}
          onSave={(text) => {
            addNoteComment(path, { section: unpaired, text })
            setCommenting(undefined)
          }}
          onCancel={() => setCommenting(undefined)}
        />
      )}
      {properties.length > 0 && (
        <details className="properties-box" aria-label="Properties">
          <summary>
            <span className="muted small">Properties</span>
            <span className="properties-line">
              {summary.id !== null && <span className="mono">{summary.id}</span>}
              {summary.status !== null && <span className="chip-plain">{summary.status}</span>}
              {summary.updated !== null && (
                <span className="muted small">updated {summary.updated}</span>
              )}
              {summary.tags.map((tag) => (
                <span key={tag} className="chip-plain">
                  {tag}
                </span>
              ))}
            </span>
          </summary>
          <dl className="properties">
            {properties.map(([key, value]) => (
              <Property key={key} name={key} value={value} />
            ))}
          </dl>
        </details>
      )}
      <article className="note-body" ref={article}>
        <BodyHeadingsContext value={bodyHeadings}>
          <Markdown
            remarkPlugins={[remarkGfm]}
            urlTransform={safeUrl}
            components={{
              ...HEADING_COMPONENTS,
              a({ href, children }) {
                const target = wikilinkTarget(href ?? '')
                if (target !== null) {
                  const where = resolveLink(index, target, linked)
                  return where === null ? (
                    <span className="muted" title="There is no such note">
                      {children}
                    </span>
                  ) : (
                    <a
                      href={`#${where}`}
                      className="wikilink"
                      onClick={(event) => {
                        event.preventDefault()
                        onOpen({ kind: 'note', path: where })
                      }}
                    >
                      {children}
                    </a>
                  )
                }
                return (
                  <a href={href} target="_blank" rel="noreferrer noopener">
                    {children}
                  </a>
                )
              },
            }}
          >
            {body}
          </Markdown>
        </BodyHeadingsContext>
      </article>
      <div className="note-links">
        {links.state.status === 'ready' && links.state.data.length > 0 && (
          <section aria-label="Links">
            <h2 className="attention-title">Links</h2>
            <ul className="attention-list">
              {links.state.data.map((target) => (
                <li key={target}>
                  <button
                    className="attention-item attention-link"
                    onClick={() => onOpen({ kind: 'note', path: target })}
                  >
                    <span className="attention-label">{titleOf(target)}</span>
                    <span className="muted small">{target}</span>
                  </button>
                </li>
              ))}
            </ul>
          </section>
        )}
        {backlinks.state.status === 'ready' && backlinks.state.data.length > 0 && (
          <section aria-label="Linked from">
            <h2 className="attention-title">Linked from</h2>
            <ul className="attention-list">
              {backlinks.state.data.map((from) => (
                <li key={from.path}>
                  <button
                    className="attention-item attention-link"
                    onClick={() => onOpen({ kind: 'note', path: from.path })}
                  >
                    <span className="attention-label">{titleOf(from.path)}</span>
                    <span className="muted small">{from.path}</span>
                  </button>
                </li>
              ))}
            </ul>
          </section>
        )}
      </div>
    </div>
  )
}
