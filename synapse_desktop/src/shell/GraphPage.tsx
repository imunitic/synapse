import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  filterPaths,
  findSymbol,
  listCoveredPaths,
  listGraphs,
  listNodes,
  listUnassigned,
  nodeNotePath,
  ownersOf,
  type Graph,
  type SymbolHit,
} from '../domain/graph-search.ts'
import { transport } from '../transport/index.ts'
import type { Page } from './state.ts'
import { useLoad } from './useLoad.ts'

type Mode = 'symbol' | 'files' | 'nodes'

const NAMESPACE_KEY = 'synapse-desktop.graph-namespace'
const MAX_ROWS = 300

function remembered(): string | null {
  try {
    return localStorage.getItem(NAMESPACE_KEY)
  } catch {
    return null
  }
}

export function remember(namespace: string): void {
  try {
    localStorage.setItem(NAMESPACE_KEY, namespace)
  } catch {
    // The choice is only a convenience.
  }
}

// What a mode needs a namespace to have, or null when it has it.
function missing(graph: Graph, mode: Mode): string | null {
  if (mode === 'symbol') {
    return graph.hasRefs
      ? null
      : 'This namespace has no reference index, so symbols cannot be searched.'
  }
  return graph.hasIndex
    ? null
    : 'This namespace has no node index, so it has no nodes or covered files here.'
}

function Hits({ hits, all }: { hits: SymbolHit[]; all: boolean }) {
  const shown = hits.slice(0, MAX_ROWS)
  const groups: [string, SymbolHit[]][] = all
    ? [
        ['Definitions', shown.filter((h) => h.role === 'def')],
        ['References', shown.filter((h) => h.role === 'ref')],
      ]
    : [['Calls', shown]]
  return (
    <>
      {groups.map(([title, rows]) =>
        rows.length === 0 ? null : (
          <section key={title} className="attention-group" aria-label={title}>
            <h3 className="attention-title">
              {title}
              <span className="count-pill">{rows.length}</span>
            </h3>
            <ul className="hits">
              {rows.map((hit, i) => (
                <li key={i} className="hit">
                  <span className="mono small hit-place">
                    {hit.path}
                    {hit.line !== null && `:${hit.line}`}
                  </span>
                  {hit.kind !== null && <span className="chip-plain">{hit.kind}</span>}
                  <code className="hit-expression">{hit.expression}</code>
                </li>
              ))}
            </ul>
          </section>
        ),
      )}
      {hits.length > MAX_ROWS && (
        <p className="muted small">
          and {hits.length - MAX_ROWS} more; search for something narrower
        </p>
      )}
    </>
  )
}

function SymbolSearch({ namespace }: { namespace: string }) {
  const [draft, setDraft] = useState('')
  const [all, setAll] = useState(false)
  const [state, setState] = useState<
    | { status: 'idle' }
    | { status: 'busy' }
    | { status: 'ready'; name: string; all: boolean; hits: SymbolHit[] }
    | { status: 'failed'; error: string }
  >({ status: 'idle' })

  async function search(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    const name = draft.trim()
    if (name === '') return
    setState({ status: 'busy' })
    try {
      setState({
        status: 'ready',
        name,
        all,
        hits: await findSymbol(transport, namespace, name, all),
      })
    } catch (error) {
      setState({ status: 'failed', error: String(error) })
    }
  }

  return (
    <>
      <form className="row" role="search" onSubmit={(event) => void search(event)}>
        <input
          className="mono grow"
          aria-label="Symbol name"
          placeholder="An exact name, such as Work_Dir"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
        <label className="check small">
          <input type="checkbox" checked={all} onChange={(event) => setAll(event.target.checked)} />
          Definitions and every reference
        </label>
        <button type="submit" className="primary" disabled={draft.trim() === ''}>
          Search
        </button>
      </form>
      {state.status === 'busy' && <p className="muted">Searching…</p>}
      {state.status === 'failed' && <p role="alert">{state.error}</p>}
      {state.status === 'ready' && state.hits.length === 0 && (
        <p className="muted">
          Nothing is {state.all ? 'defined or referred to' : 'called'} as <code>{state.name}</code>{' '}
          in {namespace}. The name has to be exact.
        </p>
      )}
      {state.status === 'ready' && <Hits hits={state.hits} all={state.all} />}
    </>
  )
}

function FileSearch({ namespace, onOpen }: { namespace: string; onOpen: (page: Page) => void }) {
  const load = useCallback(() => listCoveredPaths(transport, namespace), [namespace])
  const { state: paths } = useLoad(load)
  const [query, setQuery] = useState('')
  const [chosen, setChosen] = useState<string | null>(null)
  const loadOwners = useCallback(
    () => (chosen === null ? Promise.resolve([]) : ownersOf(transport, namespace, chosen)),
    [namespace, chosen],
  )
  const { state: owners } = useLoad(loadOwners)
  const matches = useMemo(
    () => (paths.status === 'ready' ? filterPaths(paths.data, query, 100) : []),
    [paths, query],
  )

  return (
    <>
      <input
        className="mono"
        aria-label="File path"
        placeholder={
          paths.status === 'ready'
            ? `Words of a path, among ${paths.data.length} files`
            : 'Words of a path'
        }
        value={query}
        onChange={(event) => setQuery(event.target.value)}
      />
      {paths.status === 'loading' && <p className="muted">Loading the files…</p>}
      {paths.status === 'failed' && <p role="alert">{paths.error}</p>}
      {paths.status === 'ready' && query.trim() !== '' && matches.length === 0 && (
        <p className="muted">No covered file has those words.</p>
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

function Nodes({ namespace, onOpen }: { namespace: string; onOpen: (page: Page) => void }) {
  const loadNodes = useCallback(() => listNodes(transport, namespace), [namespace])
  const loadUnassigned = useCallback(() => listUnassigned(transport, namespace), [namespace])
  const { state: nodes } = useLoad(loadNodes)
  const { state: unassigned } = useLoad(loadUnassigned)

  return (
    <>
      {nodes.status === 'loading' && <p className="muted">Loading…</p>}
      {nodes.status === 'failed' && <p role="alert">{nodes.error}</p>}
      {nodes.status === 'ready' && (
        <section aria-label="Nodes">
          <h3 className="attention-title">
            Nodes<span className="count-pill">{nodes.data.length}</span>
          </h3>
          <ul className="attention-list">
            {nodes.data.map((node) => (
              <li key={node}>
                <button
                  className="attention-item attention-link"
                  onClick={() => onOpen({ kind: 'note', path: nodeNotePath(namespace, node) })}
                >
                  <span className="attention-label">{node.replace(/\.md$/, '')}</span>
                </button>
              </li>
            ))}
          </ul>
        </section>
      )}
      {unassigned.status === 'ready' && unassigned.data.length > 0 && (
        <details className="card" aria-label="Unassigned files">
          <summary>
            {unassigned.data.length} {unassigned.data.length === 1 ? 'file is' : 'files are'}{' '}
            claimed by no node
          </summary>
          <ul className="hits">
            {unassigned.data.slice(0, MAX_ROWS).map((path) => (
              <li key={path} className="mono small">
                {path}
              </li>
            ))}
          </ul>
        </details>
      )}
    </>
  )
}

const MODES: { mode: Mode; label: string }[] = [
  { mode: 'symbol', label: 'Symbol' },
  { mode: 'files', label: 'Files' },
  { mode: 'nodes', label: 'Nodes' },
]

// Searching what a code graph keeps locally: its symbols, the files its nodes
// cover and the nodes themselves, for the namespace chosen. The nodes' notes are
// in the vault, which is where a node opens.
export function GraphPage({ onOpen }: { onOpen: (page: Page) => void }) {
  const loadGraphs = useCallback(() => listGraphs(transport), [])
  const { state: graphs, reload } = useLoad(loadGraphs)
  const [chosen, setChosen] = useState<string | null>(remembered())
  const [mode, setMode] = useState<Mode>('symbol')

  const list = graphs.status === 'ready' ? graphs.data : []
  const graph = list.find((g) => g.namespace === chosen) ?? list[0]

  // A mode the namespace cannot serve gives way to one it can.
  useEffect(() => {
    if (graph === undefined) return
    if (missing(graph, mode) === null) return
    const next = MODES.find((m) => missing(graph, m.mode) === null)
    if (next !== undefined) setMode(next.mode)
  }, [graph, mode])

  return (
    <div className="page wide graph-page">
      <h1 className="page-title">Code graph</h1>
      {graphs.status === 'loading' && <p className="muted">Looking for graphs…</p>}
      {graphs.status === 'failed' && <p role="alert">Could not look for graphs: {graphs.error}</p>}
      {graphs.status === 'ready' && list.length === 0 && (
        <p className="muted">
          No graph has local files yet. Build one in a repository with the{' '}
          <code>/synapse-init</code> skill, and it shows here.
        </p>
      )}
      {graph !== undefined && (
        <>
          <div className="row graph-controls">
            <label className="field">
              <span className="muted small">Namespace</span>
              <select
                aria-label="Namespace"
                value={graph.namespace}
                onChange={(event) => {
                  setChosen(event.target.value)
                  remember(event.target.value)
                }}
              >
                {list.map((g) => (
                  <option key={g.namespace} value={g.namespace}>
                    {g.namespace}
                  </option>
                ))}
              </select>
            </label>
            <span className="muted small">
              has{' '}
              {[
                graph.hasIndex && 'a node index',
                graph.hasRefs && 'references',
                graph.hasTags && 'tags',
              ]
                .filter(Boolean)
                .join(', ')}
            </span>
            <button className="link" onClick={reload}>
              Look again
            </button>
          </div>
          <div className="subtabs graph-tabs" role="tablist" aria-label="What to search">
            {MODES.map(({ mode: m, label }) => (
              <button
                key={m}
                className="subtab"
                role="tab"
                aria-selected={mode === m}
                aria-pressed={mode === m}
                disabled={missing(graph, m) !== null}
                title={missing(graph, m) ?? undefined}
                onClick={() => setMode(m)}
              >
                {label}
              </button>
            ))}
          </div>
          {missing(graph, mode) !== null ? (
            <p className="muted">{missing(graph, mode)}</p>
          ) : (
            <div key={`${graph.namespace}:${mode}`} className="graph-body">
              {mode === 'symbol' && <SymbolSearch namespace={graph.namespace} />}
              {mode === 'files' && <FileSearch namespace={graph.namespace} onOpen={onOpen} />}
              {mode === 'nodes' && <Nodes namespace={graph.namespace} onOpen={onOpen} />}
            </div>
          )}
        </>
      )}
    </div>
  )
}
