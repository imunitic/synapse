import { useCallback, useEffect, useState } from 'react'
import { listGraphs, type Graph } from '../domain/graph-search.ts'
import { transport } from '../transport/index.ts'
import { type Page, type TerminalKind, type TerminalTask } from '../state/state.ts'
import { useLoad } from '../state/useLoad.ts'
import { FileSearch } from './graph/FileSearch.tsx'
import { Health } from './graph/Health.tsx'
import { Manage } from './graph/Manage.tsx'
import { NewGraph } from './graph/NewGraph.tsx'
import { Nodes } from './graph/Nodes.tsx'
import { RepoRow } from './graph/RepoRow.tsx'
import { SymbolSearch } from './graph/SymbolSearch.tsx'
import { remember, remembered } from './graph/namespace.ts'

type Mode = 'symbol' | 'files' | 'nodes' | 'health' | 'manage'

// What a mode needs a namespace to have, or null when it has it.
function missing(graph: Graph, mode: Mode): string | null {
  // Managing a graph works on the repository saved for it, which any namespace can have.
  if (mode === 'manage') return null
  // Health reads the nodes and compares them with the repository's files.
  if (mode === 'health') {
    return graph.hasIndex
      ? null
      : 'This namespace has no node index here, so there is nothing to check.'
  }
  if (mode === 'symbol') {
    return graph.hasRefs
      ? null
      : 'This namespace has no reference index, so symbols cannot be searched.'
  }
  return graph.hasIndex
    ? null
    : 'This namespace has no node index, so it has no nodes or covered files here.'
}

const MODES: { mode: Mode; label: string }[] = [
  { mode: 'symbol', label: 'Symbol' },
  { mode: 'files', label: 'Files' },
  { mode: 'nodes', label: 'Nodes' },
  { mode: 'health', label: 'Health' },
  { mode: 'manage', label: 'Manage' },
]

// Searching what a code graph keeps locally: its symbols, the files its nodes
// cover and the nodes themselves, for the namespace chosen. The nodes' notes are
// in the vault, which is where a node opens.
export function GraphPage({
  onOpen,
  onStartTask,
}: {
  onOpen: (page: Page) => void
  onStartTask: (kind: TerminalKind, cwd: string, task: TerminalTask) => void
}) {
  const loadGraphs = useCallback(() => listGraphs(transport), [])
  const { state: graphs, reload } = useLoad(loadGraphs)
  const [chosen, setChosen] = useState<string | null>(remembered())
  const [mode, setMode] = useState<Mode>('symbol')
  const [building, setBuilding] = useState(false)

  const list = graphs.status === 'ready' ? graphs.data : []
  // A graph is added from the place where one is chosen.
  const newGraph = (
    <button className="secondary" disabled={building} onClick={() => setBuilding(true)}>
      New graph…
    </button>
  )
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
      <div className="graph-head">
        <h1 className="page-title">Code graph</h1>
      </div>
      {building && (
        <NewGraph
          existing={list.map((g) => g.namespace)}
          onSelect={(namespace) => {
            setChosen(namespace)
            remember(namespace)
          }}
          onStartTask={onStartTask}
          onClose={() => setBuilding(false)}
        />
      )}
      {graphs.status === 'loading' && <p className="muted">Looking for graphs…</p>}
      {graphs.status === 'failed' && <p role="alert">Could not look for graphs: {graphs.error}</p>}
      {graphs.status === 'ready' && list.length === 0 && (
        <p className="muted">
          No graph has local files yet. Build one from a repository with New graph, and it shows
          here.
        </p>
      )}
      {graphs.status === 'ready' && list.length === 0 && newGraph}
      {graph !== undefined && (
        <>
          <div className="graph-bar">
            <span className="muted small">Namespace</span>
            <div className="row graph-controls">
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
              {newGraph}
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
            <RepoRow namespace={graph.namespace} />
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
              {mode === 'health' && <Health namespace={graph.namespace} onOpen={onOpen} />}
              {mode === 'manage' && (
                <Manage namespace={graph.namespace} onChanged={reload} onStartTask={onStartTask} />
              )}
            </div>
          )}
        </>
      )}
    </div>
  )
}
