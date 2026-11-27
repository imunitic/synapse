import { useState, type Dispatch } from 'react'
import { definitionUse, type DefinitionUse } from '../domain/definition-use.ts'
import { loadDefinitions } from '../domain/definitions.ts'
import { filterByName } from '../domain/filter.ts'
import { transport } from '../transport/index.ts'
import { CloneDialog } from '../components/CloneDialog.tsx'
import { CopyIcon, PlayIcon, PlusIcon, RefreshIcon, TrashIcon } from '../components/icons.tsx'
import {
  DEFINITION_KINDS,
  DEFINITION_LABELS,
  pageId,
  type Action,
  type DefinitionKind,
  type ShellState,
} from '../state/state.ts'
import { useLoad } from '../state/useLoad.ts'
import { useWatch } from '../state/useWatch.ts'

function loadAll() {
  return loadDefinitions(transport)
}

interface Item {
  name: string
  path: string
  description: string | null
}

// The last part of a path, for a list that has little room.
function baseName(path: string): string {
  return path.slice(path.lastIndexOf('/') + 1)
}

// Where a deletion has got to. A definition that something uses is not deleted: it says what
// uses it. Otherwise the person is asked once.
type Removal =
  | { step: 'checking' }
  | { step: 'blocked'; use: DefinitionUse }
  | { step: 'confirm' }
  | { step: 'removing' }
  | { step: 'failed'; error: string }

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function DefinitionRow({
  kind,
  item,
  active,
  dispatch,
}: {
  kind: DefinitionKind
  item: Item
  active: boolean
  dispatch: Dispatch<Action>
}) {
  const [removal, setRemoval] = useState<Removal | null>(null)
  const [cloning, setCloning] = useState(false)
  const singular = DEFINITION_LABELS[kind].singular
  const page = { kind: 'definition', definition: kind, name: item.name, path: item.path } as const

  async function check() {
    setRemoval({ step: 'checking' })
    try {
      const use = await definitionUse(transport, kind, item.name)
      setRemoval(
        use.users.length > 0 || use.unchecked.length > 0
          ? { step: 'blocked', use }
          : { step: 'confirm' },
      )
    } catch (error) {
      setRemoval({ step: 'failed', error: messageOf(error) })
    }
  }

  async function remove() {
    setRemoval({ step: 'removing' })
    try {
      await transport.deleteDefinition(item.path)
      dispatch({ type: 'closeTab', id: pageId(page) })
      dispatch({ type: 'definitionsChanged' })
    } catch (error) {
      setRemoval({ step: 'failed', error: messageOf(error) })
    }
  }

  return (
    <div className="list-entry">
      <div className="list-row">
        <button
          className="list-item"
          aria-current={active ? 'true' : undefined}
          onClick={() => dispatch({ type: 'openPage', page })}
        >
          <span className="list-line">
            <span className="list-name">{item.name}</span>
            {item.description !== null && item.description !== '' && (
              <span className="muted small list-name-one-line" title={item.description}>
                {item.description}
              </span>
            )}
          </span>
        </button>
        {kind === 'pipeline' && (
          <button
            className="icon-button list-action list-run"
            aria-label={`Run ${item.name}`}
            title={`Run ${item.name}`}
            onClick={() => dispatch({ type: 'openRunDialog', pipeline: item.name })}
          >
            <PlayIcon />
          </button>
        )}
        {kind === 'pipeline' && (
          <button
            className="icon-button list-action list-run"
            aria-label={`Clone ${item.name}`}
            title={`Clone ${item.name}`}
            onClick={() => setCloning(true)}
          >
            <CopyIcon />
          </button>
        )}
        <button
          className="icon-button list-action"
          aria-label={`Delete this ${singular}`}
          title={`Delete ${item.name}`}
          disabled={removal?.step === 'checking' || removal?.step === 'removing'}
          onClick={() => void check()}
        >
          <TrashIcon />
        </button>
      </div>
      {cloning && (
        <CloneDialog
          name={item.name}
          path={item.path}
          onClose={() => setCloning(false)}
          onCloned={(copy, written) => {
            setCloning(false)
            dispatch({ type: 'definitionsChanged' })
            dispatch({
              type: 'openPage',
              page: { kind: 'definition', definition: 'pipeline', name: copy, path: written },
            })
          }}
        />
      )}
      {removal?.step === 'blocked' && (
        <div className="confirm" role="alert">
          <p>
            <strong>{item.name}</strong> cannot be deleted yet.
          </p>
          {removal.use.users.length > 0 && (
            <>
              <p className="small">It is used by:</p>
              <ul className="small">
                {removal.use.users.map((user) => (
                  <li key={`${user.kind}:${user.name}`}>
                    {user.kind} <span className="mono">{user.name}</span>
                    {user.steps.length > 0 && (
                      <span className="muted"> · step {user.steps.join(', ')}</span>
                    )}
                  </li>
                ))}
              </ul>
              <p className="small">Delete those first.</p>
            </>
          )}
          {removal.use.unchecked.length > 0 && (
            <p className="small">
              It cannot be told whether it is used by {removal.use.unchecked.join(', ')}, which{' '}
              cannot be read.
            </p>
          )}
          <button className="secondary" onClick={() => setRemoval(null)}>
            Close
          </button>
        </div>
      )}
      {(removal?.step === 'confirm' || removal?.step === 'removing') && (
        <div className="confirm" role="alertdialog" aria-label="Are you sure?">
          <p>
            <strong>
              Delete {singular} {item.name}?
            </strong>
          </p>
          <p className="small mono">{item.path}</p>
          <p className="small">The file is removed. It cannot be undone.</p>
          <div className="row">
            <button
              className="danger"
              disabled={removal.step === 'removing'}
              onClick={() => void remove()}
            >
              Yes, delete
            </button>
            <button
              className="secondary"
              disabled={removal.step === 'removing'}
              onClick={() => setRemoval(null)}
            >
              Cancel
            </button>
          </div>
        </div>
      )}
      {removal?.step === 'failed' && (
        <div className="confirm" role="alert">
          <p>
            Could not delete {item.name}: {removal.error}
          </p>
          <button className="secondary" onClick={() => setRemoval(null)}>
            Close
          </button>
        </div>
      )}
    </div>
  )
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
  useWatch('definitions', reload)
  const kind = state.definitionKind
  const labels = DEFINITION_LABELS[kind]
  const [filter, setFilter] = useState('')

  let items: Item[] = []
  if (load.status === 'ready') {
    items = load.data.definitions.filter((d) => d.kind === kind)
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
          <DefinitionRow
            key={item.path}
            kind={kind}
            item={item}
            active={state.activeId === `definition:${kind}:${item.name}`}
            dispatch={dispatch}
          />
        ))}
      </div>
      {load.status === 'ready' && load.data.problems.length > 0 && (
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
