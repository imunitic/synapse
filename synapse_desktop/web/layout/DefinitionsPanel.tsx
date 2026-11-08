import { useState, type Dispatch } from 'react'
import { listSkills, loadDefinitions } from '../domain/definitions.ts'
import { filterByName } from '../domain/filter.ts'
import { transport } from '../transport/index.ts'
import { PlusIcon, RefreshIcon } from '../components/icons.tsx'
import {
  DEFINITION_KINDS,
  DEFINITION_LABELS,
  type Action,
  type ShellState,
} from '../state/state.ts'
import { useLoad } from '../state/useLoad.ts'

async function loadAll() {
  const [{ definitions, problems }, skills] = await Promise.all([
    loadDefinitions(transport),
    listSkills(transport),
  ])
  return { definitions, problems, skills }
}

interface Item {
  name: string
  path: string
}

// The last part of a path, for a list that has little room.
function baseName(path: string): string {
  return path.slice(path.lastIndexOf('/') + 1)
}

export function DefinitionsPanel({
  state,
  dispatch,
}: {
  state: ShellState
  dispatch: Dispatch<Action>
}) {
  // Read again when a definition has been made.
  const { state: load, reload } = useLoad(loadAll, undefined, state.reloadToken)
  const kind = state.definitionKind
  const labels = DEFINITION_LABELS[kind]
  const [filter, setFilter] = useState('')

  let items: Item[] = []
  if (load.status === 'ready') {
    items =
      kind === 'skill' ? load.data.skills : load.data.definitions.filter((d) => d.kind === kind)
  }

  const shown = filterByName(items, filter)

  return (
    <>
      <div className="panel-header">
        <h2 className="panel-title">Definitions</h2>
        <div className="row">
          <button className="icon-button" aria-label="Refresh the lists" onClick={reload}>
            <RefreshIcon />
          </button>
          <button
            className="icon-button"
            aria-label={`New ${labels.singular}`}
            onClick={() =>
              dispatch({ type: 'openPage', page: { kind: 'create', definition: kind } })
            }
          >
            <PlusIcon />
          </button>
        </div>
      </div>
      <div className="subtabs" role="group" aria-label="Kind of definition">
        {DEFINITION_KINDS.map((k) => (
          <button
            key={k}
            className="subtab"
            aria-pressed={kind === k}
            onClick={() => dispatch({ type: 'selectDefinitionKind', kind: k })}
          >
            {DEFINITION_LABELS[k].plural}
          </button>
        ))}
      </div>
      <div className="panel-search">
        <input
          type="search"
          aria-label={`Filter the ${labels.plural.toLowerCase()}`}
          placeholder="Filter…"
          value={filter}
          onChange={(event) => setFilter(event.target.value)}
        />
      </div>
      {load.status === 'loading' && <p className="panel-empty">Loading…</p>}
      {load.status === 'failed' && (
        <p className="panel-empty" role="alert">
          {load.error}
        </p>
      )}
      {load.status === 'ready' && items.length === 0 && (
        <p className="panel-empty">No {labels.plural.toLowerCase()} found.</p>
      )}
      {load.status === 'ready' && items.length > 0 && shown.length === 0 && (
        <p className="panel-empty">
          No {labels.plural.toLowerCase()} match “{filter.trim()}”.
        </p>
      )}
      <div className="list">
        {shown.map((item) => (
          <button
            key={item.path}
            className="list-item"
            aria-current={state.activeId === `definition:${kind}:${item.name}` ? 'true' : undefined}
            onClick={() =>
              dispatch({
                type: 'openPage',
                page: { kind: 'definition', definition: kind, name: item.name, path: item.path },
              })
            }
          >
            <span className="list-name">{item.name}</span>
          </button>
        ))}
      </div>
      {load.status === 'ready' && kind !== 'skill' && load.data.problems.length > 0 && (
        <section className="panel-problems" aria-label="Files that did not load">
          <h3 className="panel-subtitle">Did not load</h3>
          <ul>
            {load.data.problems.map((problem) => (
              <li key={`${problem.file}:${problem.line}:${problem.column}:${problem.message}`}>
                <span className="mono" title={problem.file}>
                  {problem.file === '' ? 'a directory' : baseName(problem.file)}
                </span>
                <span className="muted small"> {problem.message}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </>
  )
}
