import { useCallback, useEffect, useMemo, type ReactNode } from 'react'
import Markdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import {
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
import { recordOpened } from '../domain/recent.ts'
import { transport } from '../transport/index.ts'
import type { Page } from './state.ts'
import { useLoad } from './useLoad.ts'

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

// A note of the vault: its properties, its text, and the notes it links to and
// is linked from.
export function NotePage({ path, onOpen }: { path: string; onOpen: (page: Page) => void }) {
  const read = useCallback(() => readNote(transport, path), [path])
  const readLinks = useCallback(() => noteLinks(transport, path), [path])
  const readBacklinks = useCallback(() => noteBacklinks(transport, path), [path])
  const readAll = useCallback(() => listNotes(transport), [])
  const note = useLoad(read)
  // A note that was read is one that was opened, which the home page offers again.
  useEffect(() => {
    if (note.state.status === 'ready') recordOpened(path)
  }, [note.state.status, path])
  const links = useLoad(readLinks)
  const backlinks = useLoad(readBacklinks)
  const all = useLoad(readAll)

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

  if (note.state.status === 'loading') return <p className="muted">Loading…</p>
  if (note.state.status === 'failed') {
    return <p role="alert">Could not read the note: {note.state.error}</p>
  }
  const { title, frontmatter } = note.state.data
  const properties = Object.entries(frontmatter ?? {}).filter(([key]) => key !== 'title')

  return (
    <div className="page note">
      <p className="eyebrow">
        {path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : 'Vault'}
      </p>
      <h1 className="page-title">{title}</h1>
      {properties.length > 0 && (
        <dl className="properties" aria-label="Properties">
          {properties.map(([key, value]) => (
            <Property key={key} name={key} value={value} />
          ))}
        </dl>
      )}
      <article className="note-body">
        <Markdown
          remarkPlugins={[remarkGfm]}
          urlTransform={safeUrl}
          components={{
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
