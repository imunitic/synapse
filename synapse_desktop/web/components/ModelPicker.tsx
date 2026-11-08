import { useEffect, useId, useMemo, useState } from 'react'
import type { Harness, ModelCatalog } from '../../shared/transport.ts'
import { filterModels, isModelName } from '../domain/models.ts'
import { transport } from '../transport/index.ts'

// How many models the list shows at once: the rest are found by typing.
const SHOWN = 40

// The models of each harness, asked for once and when a picker is first used, since OpenCode has
// hundreds and printing them is not free.
const catalogs = new Map<Harness, Promise<ModelCatalog>>()

function catalogOf(harness: Harness): Promise<ModelCatalog> {
  let found = catalogs.get(harness)
  if (found === undefined) {
    found = transport.listModels(harness).catch((error: unknown) => {
      // A list that could not be had is asked for again the next time.
      catalogs.delete(harness)
      throw error
    })
    catalogs.set(harness, found)
  }
  return found
}

type Catalog =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'ready'; catalog: ModelCatalog }
  | { status: 'failed'; error: string }

const BAD_NAME =
  'A model name has letters, digits and the characters . _ : / @ + ~ - and starts with a letter or a digit.'

// A choice of a model for a harness: its own list to search when it has one, and a name to type
// when it has not. Choosing none leaves the model to the harness.
export function ModelPicker({
  harness,
  value,
  onChange,
  label,
  disabled = false,
}: {
  harness: Harness
  value: string | null
  onChange: (model: string | null) => void
  label: string
  disabled?: boolean
}) {
  const id = useId()
  const [draft, setDraft] = useState(value ?? '')
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(0)
  const [problem, setProblem] = useState<string | null>(null)
  const [catalog, setCatalog] = useState<Catalog>({ status: 'idle' })

  // The list is read as soon as a picker is there, since Claude Code takes a few seconds to
  // answer, and is ready by the time the box is used.
  useEffect(() => {
    if (!disabled) load()
    // `load` only starts the reading, once.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [harness, disabled])

  // What was chosen elsewhere, or was saved, is what is shown.
  useEffect(() => {
    setDraft(value ?? '')
    setProblem(null)
  }, [value])

  function load() {
    if (catalog.status !== 'idle' && catalog.status !== 'failed') return
    setCatalog({ status: 'loading' })
    catalogOf(harness).then(
      (found) => setCatalog({ status: 'ready', catalog: found }),
      (error: unknown) => setCatalog({ status: 'failed', error: String(error) }),
    )
  }

  const found = useMemo(
    () =>
      catalog.status === 'ready'
        ? filterModels(catalog.catalog.models, draft === value ? '' : draft, SHOWN)
        : { shown: [], total: 0 },
    [catalog, draft, value],
  )

  function commit(text: string) {
    const name = text.trim()
    if (name === '') {
      setProblem(null)
      setDraft('')
      if (value !== null) onChange(null)
      return
    }
    if (!isModelName(name)) {
      setProblem(BAD_NAME)
      return
    }
    setProblem(null)
    setDraft(name)
    if (name !== value) onChange(name)
  }

  function choose(model: string) {
    commit(model)
    setOpen(false)
  }

  const listed = open && found.shown.length > 0
  const optionId = (index: number) => `${id}-option-${index}`

  return (
    <div className="model-picker">
      <div className="row">
        <input
          className="mono model-input"
          role="combobox"
          aria-label={label}
          aria-expanded={listed}
          aria-controls={`${id}-list`}
          aria-autocomplete="list"
          aria-activedescendant={listed ? optionId(active) : undefined}
          value={draft}
          disabled={disabled}
          placeholder="The model the harness uses itself"
          onFocus={() => {
            load()
            setOpen(true)
          }}
          onChange={(event) => {
            setDraft(event.target.value)
            setProblem(null)
            setActive(0)
            setOpen(true)
          }}
          onBlur={() => {
            setOpen(false)
            if (draft.trim() !== (value ?? '')) commit(draft)
          }}
          onKeyDown={(event) => {
            if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
              event.preventDefault()
              setOpen(true)
              const step = event.key === 'ArrowDown' ? 1 : -1
              setActive((now) =>
                Math.min(Math.max(now + step, 0), Math.max(found.shown.length - 1, 0)),
              )
            } else if (event.key === 'Enter') {
              event.preventDefault()
              const picked = listed ? found.shown[active] : undefined
              if (picked === undefined) commit(draft)
              else choose(picked.id)
            } else if (event.key === 'Escape') {
              setOpen(false)
              setDraft(value ?? '')
              setProblem(null)
            }
          }}
        />
        {value !== null && (
          <button type="button" className="link" disabled={disabled} onClick={() => commit('')}>
            Use the harness's own
          </button>
        )}
      </div>
      {problem !== null && (
        <p className="error small" role="alert">
          {problem}
        </p>
      )}
      {listed && (
        <ul
          className="model-list"
          role="listbox"
          id={`${id}-list`}
          aria-label={`Models of ${label}`}
        >
          {found.shown.map((model, index) => (
            <li
              key={model.id}
              id={optionId(index)}
              role="option"
              aria-selected={index === active}
              data-unavailable={model.available ? undefined : true}
              // Taken on the press, before the input loses the focus and shuts the list.
              onMouseDown={(event) => {
                event.preventDefault()
                choose(model.id)
              }}
              onMouseEnter={() => setActive(index)}
            >
              <span className="mono">{model.id}</span>
              {!model.available && <span className="muted small"> not connected</span>}
              {model.detail !== null && <span className="muted small"> {model.detail}</span>}
            </li>
          ))}
          {found.total > found.shown.length && (
            <li className="model-more muted small" role="presentation">
              {found.shown.length} of {found.total} models: type to narrow them
            </li>
          )}
        </ul>
      )}
      {catalog.status === 'loading' && open && <p className="muted small">Reading the models…</p>}
      {catalog.status === 'failed' && (
        <p className="muted small">The models could not be listed. Type a name instead.</p>
      )}
      {catalog.status === 'ready' && open && catalog.catalog.note !== null && (
        <p className="muted small">{catalog.catalog.note}</p>
      )}
      {catalog.status === 'ready' &&
        open &&
        found.total === 0 &&
        draft.trim() !== '' &&
        catalog.catalog.models.length > 0 && (
          <p className="muted small">
            No listed model has those words. The name typed is used as it is.
          </p>
        )}
    </div>
  )
}
