import { useCallback, useMemo, useState } from 'react'
import { listCoveredPaths, nodeNotePath, ownersOf, searchPaths } from '../../domain/graph-search.ts'
import { transport } from '../../transport/index.ts'
import { type Page } from '../../state/state.ts'
import { useLoad } from '../../state/useLoad.ts'

export function FileSearch({
  namespace,
  onOpen,
}: {
  namespace: string
  onOpen: (page: Page) => void
}) {
  const load = useCallback(() => listCoveredPaths(transport, namespace), [namespace])
  const { state: paths } = useLoad(load)
  // What is typed, and what was searched for when it was asked for.
  const [draft, setDraft] = useState('')
  const [query, setQuery] = useState<string | null>(null)
  const [chosen, setChosen] = useState<string | null>(null)
  const loadOwners = useCallback(
    () => (chosen === null ? Promise.resolve([]) : ownersOf(transport, namespace, chosen)),
    [namespace, chosen],
  )
  const { state: owners } = useLoad(loadOwners)
  const found = useMemo(
    () =>
      paths.status === 'ready' && query !== null
        ? searchPaths(paths.data, query, 100)
        : { paths: [], total: 0 },
    [paths, query],
  )
  const matches = found.paths

  return (
    <>
      <form
        className="row"
        role="search"
        onSubmit={(event) => {
          event.preventDefault()
          setQuery(draft.trim())
          setChosen(null)
        }}
      >
        <input
          className="mono grow"
          aria-label="File path"
          placeholder={
            paths.status === 'ready'
              ? `Words of a path, among ${paths.data.length} files`
              : 'Words of a path'
          }
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
        <button
          type="submit"
          className="primary"
          disabled={draft.trim() === '' || paths.status !== 'ready'}
        >
          Search
        </button>
      </form>
      {paths.status === 'loading' && <p className="muted">Loading the files…</p>}
      {paths.status === 'failed' && <p role="alert">{paths.error}</p>}
      {paths.status === 'ready' && query !== null && matches.length === 0 && (
        <p className="muted">No covered file has those words.</p>
      )}
      {matches.length > 0 && (
        <p className="muted small">
          {found.total > matches.length
            ? `${matches.length} of ${found.total} files`
            : `${found.total} ${found.total === 1 ? 'file' : 'files'}`}
        </p>
      )}
      <ul className="hits">
        {matches.map((path) => (
          <li key={path}>
            <button
              className="attention-item attention-link"
              aria-pressed={chosen === path}
              onClick={() => setChosen(path)}
            >
              <span className="mono small">{path}</span>
            </button>
          </li>
        ))}
      </ul>
      {chosen !== null && (
        <section className="card" aria-label="Owners">
          <h3 className="card-title">
            <span className="mono">{chosen}</span> is covered by
          </h3>
          {owners.status === 'loading' && <p className="muted">Looking…</p>}
          {owners.status === 'failed' && <p role="alert">{owners.error}</p>}
          {owners.status === 'ready' && owners.data.length === 0 && (
            <p className="muted">No node claims it.</p>
          )}
          {owners.status === 'ready' &&
            owners.data.map((node) => (
              <button
                key={node}
                className="attention-item attention-link"
                onClick={() => onOpen({ kind: 'note', path: nodeNotePath(namespace, node) })}
              >
                <span className="attention-label">{node.replace(/\.md$/, '')}</span>
              </button>
            ))}
        </section>
      )}
    </>
  )
}
