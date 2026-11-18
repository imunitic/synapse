import { useEffect, useId, useMemo, useState } from 'react'
import type { Harness, ModelCatalog } from '../../shared/transport.ts'
import { timeAgo } from '../domain/format.ts'
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
  placeholder = 'The model the harness uses itself',
  clearable,
  clearLabel = "Use the harness's own",
}: {
  harness: Harness
  value: string | null
  onChange: (model: string | null) => void
  label: string
  disabled?: boolean
  placeholder?: string
  // Whether there is a way back, which is when a model is chosen unless the caller says.
  clearable?: boolean
  clearLabel?: string
}) {
  const id = useId()
  const [draft, setDraft] = useState(value ?? '')
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(0)
  const [problem, setProblem] = useState<string | null>(null)
  const [catalog, setCatalog] = useState<Catalog>({ status: 'idle' })
  const [reading, setReading] = useState(false)

  // The list is read as soon as a picker is there, since Claude Code takes a few seconds to
  // answer, and is ready by the time the box is used.
  useEffect(() => {
    if (!disabled) load()
    // `load` only starts the reading, once.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [harness, disabled])

  // What this box last gave to `onChange`, until the caller's `value` is that. The value comes back
  // once the caller has kept it, which can be after the person has begun to type another name:
  // what was given is what is chosen meanwhile, and its return must not replace the text typed.
  const [sent, setSent] = useState<{ model: string | null } | null>(null)
  const chosen = sent === null ? value : sent.model

  // What was chosen elsewhere, or was saved, is what is shown.
  useEffect(() => {
    const returned = sent !== null && sent.model === value
    setSent(null)
    if (returned) return
    setDraft(value ?? '')
    setProblem(null)
    // Only a new `value` is read here; `sent` is what that value is compared with.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value])

  function load() {
    if (catalog.status !== 'idle' && catalog.status !== 'failed') return
    setCatalog({ status: 'loading' })
    catalogOf(harness).then(
      (found) => setCatalog({ status: 'ready', catalog: found }),
      (error: unknown) => setCatalog({ status: 'failed', error: String(error) }),
    )
  }

  // Reads the list from the harness again, as it is now: a provider may have been connected since.
  function readAgain() {
    setReading(true)
    const fresh = transport.refreshModels(harness)
    catalogs.set(harness, fresh)
    fresh
      .then(
        (found) => setCatalog({ status: 'ready', catalog: found }),
        (error: unknown) => setCatalog({ status: 'failed', error: String(error) }),
      )
      .finally(() => setReading(false))
  }

  const found = useMemo(
    () =>
      catalog.status === 'ready'
        ? filterModels(catalog.catalog.models, draft === chosen ? '' : draft, SHOWN)
        : { shown: [], total: 0 },
    [catalog, draft, chosen],
  )

  function commit(text: string) {
    const name = text.trim()
    if (name === '') {
      setProblem(null)
      setDraft('')
      if (chosen !== null) {
        setSent({ model: null })
        onChange(null)
      }
      return
    }
    if (!isModelName(name)) {
      setProblem(BAD_NAME)
      return
    }
    setProblem(null)
    setDraft(name)
    if (name !== chosen) {
      setSent({ model: name })
      onChange(name)
    }
  }

  function choose(model: string) {
    commit(model)
    setOpen(false)
  }

  const listed = open && found.shown.length > 0
  // When the list was read, and a way to read it again. It is at the foot of the list when there is
  // one, since the list lies over what is under the box, and under the box when there is not.
  const reread =
    catalog.status === 'ready' && open ? (
      <>
        {catalog.catalog.readAt === null
          ? 'Not read from the harness.'
          : `Read ${timeAgo(catalog.catalog.readAt, new Date())}.`}{' '}
        <button
          type="button"
          className="link"
          disabled={reading}
          // The box keeps the focus, so that the list stays open.
          onMouseDown={(event) => event.preventDefault()}
          onClick={readAgain}
        >
          {reading ? 'Reading…' : 'Read again'}
        </button>
      </>
    ) : null
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
          placeholder={placeholder}
          onFocus={() => {
            load()
            setOpen(true)
          }}
          // The box keeps the focus when a model is chosen, so a click opens the list again.
          onClick={() => setOpen(true)}
          onChange={(event) => {
            setDraft(event.target.value)
            setProblem(null)
            setActive(0)
            setOpen(true)
          }}
          onBlur={() => {
            setOpen(false)
            if (draft.trim() !== (chosen ?? '')) commit(draft)
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
              setDraft(chosen ?? '')
              setProblem(null)
            }
          }}
        />
        {(clearable ?? value !== null) && (
          <button type="button" className="link" disabled={disabled} onClick={() => commit('')}>
            {clearLabel}
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
          <li className="model-more muted small" role="presentation">
            {reread}
          </li>
        </ul>
      )}
      {!listed && reread !== null && <p className="muted small">{reread}</p>}
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
