import { useState, type Dispatch } from 'react'
import { listDefinitions, listSkills } from '../domain/definitions.ts'
import { filterByName } from '../domain/filter.ts'
import { transport } from '../transport/index.ts'
import { PlusIcon, RefreshIcon } from './icons.tsx'
import { DEFINITION_KINDS, DEFINITION_LABELS, type Action, type ShellState } from './state.ts'
import { useLoad } from './useLoad.ts'

async function loadAll() {
  const [definitions, skills] = await Promise.all([
    listDefinitions(transport),
    listSkills(transport),
  ])
  return { definitions, skills }
}

interface Item {
  name: string
  path: string
  duplicate: boolean
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
      kind === 'skill'
        ? load.data.skills.map((s) => ({ ...s, duplicate: false }))
        : load.data.definitions.filter((d) => d.kind === kind)
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
            {item.duplicate && <span className="list-note warn">claimed by two files</span>}
          </button>
        ))}
      </div>
    </>
  )
}
