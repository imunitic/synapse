import { useCallback, useState } from 'react'
import type { Convention, ConventionGroup } from '../../shared/transport.ts'
import { transport } from '../transport/index.ts'
import { AddProjectForm } from '../components/ProjectForm.tsx'
import { useLoad } from '../state/useLoad.ts'

const GROUPS: readonly ConventionGroup[] = ['Vault', 'Code graph', 'Prompts']

// A list of this length gets a filter, and no more than this many rows are drawn.
const FILTER_FROM = 20
const SHOWN = 100

// The cards that are open are kept for the browser tab, so that a change to one does not
// close the others. Storage may be missing or full; then every card starts closed.
const OPEN_KEY = 'synapse-conventions-open'

function readOpen(): Set<string> {
  try {
    const raw = sessionStorage.getItem(OPEN_KEY)
    const ids: unknown = raw === null ? [] : JSON.parse(raw)
    return new Set(Array.isArray(ids) ? ids.filter((id) => typeof id === 'string') : [])
  } catch {
    return new Set()
  }
}

function writeOpen(open: ReadonlySet<string>): void {
  try {
    sessionStorage.setItem(OPEN_KEY, JSON.stringify([...open]))
  } catch {
    // Not kept; the cards start closed next time.
  }
}

// What the count of a card says to a screen reader.
export function countLabel(count: number): string {
  return `${count} ${count === 1 ? 'entry' : 'entries'}`
}

function problemOf(error: unknown): string {
  return String(error).replace(/^Error: /, '')
}

function AddEntryForm({ convention, onAdded }: { convention: Convention; onAdded: () => void }) {
  const [entry, setEntry] = useState('')
  const [problem, setProblem] = useState<string | null>(null)

  async function add(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    try {
      await transport.addConvention(convention.id, entry.trim())
      setEntry('')
      setProblem(null)
      onAdded()
    } catch (error) {
      setProblem(problemOf(error))
    }
  }

  return (
    <>
      <form
        className="row"
        aria-label={`Add to ${convention.title}`}
        onSubmit={(event) => void add(event)}
      >
        <input
          aria-label={`New entry of ${convention.title}`}
          placeholder="a new entry"
          value={entry}
          onChange={(event) => setEntry(event.target.value)}
        />
        <button className="secondary" type="submit" disabled={entry.trim() === ''}>
          Add
        </button>
      </form>
      {problem !== null && (
        <p className="error" role="alert">
          {problem}
        </p>
      )}
    </>
  )
}

function ConventionBody({
  convention,
  onChanged,
}: {
  convention: Convention
  onChanged: () => void
}) {
  const [filter, setFilter] = useState('')
  const [problem, setProblem] = useState<string | null>(null)

  const wanted = filter.trim().toLowerCase()
  const matching =
    wanted === ''
      ? convention.entries
      : convention.entries.filter((e) => e.text.toLowerCase().includes(wanted))
  const shown = matching.slice(0, SHOWN)

  async function remove(entry: string) {
    try {
      await transport.removeConvention(convention.id, entry)
      setProblem(null)
      onChanged()
    } catch (error) {
      setProblem(problemOf(error))
    }
  }

  return (
    <div className="convention-body">
      <p className="muted small">
        {convention.exists ? (
          <>
            In <span className="mono">{convention.file}</span>.
          </>
        ) : (
          <>
            There is no file yet. It is made in <span className="mono">{convention.file}</span>{' '}
            {convention.editable ? 'when the first entry is added' : 'when an agent writes it'}.
          </>
        )}
      </p>
      {convention.problem !== null && (
        <p className="error" role="alert">
          {convention.problem}
        </p>
      )}
      {convention.entries.length > FILTER_FROM && (
        <input
          aria-label={`Filter ${convention.title}`}
          placeholder="Filter"
          value={filter}
          onChange={(event) => setFilter(event.target.value)}
        />
      )}
      {convention.exists && convention.problem === null && convention.entries.length === 0 && (
        <p className="muted">No entries.</p>
      )}
      {shown.length > 0 && (
        <ul className="convention-entries" aria-label={`Entries of ${convention.title}`}>
          {shown.map((entry) => (
            <li key={`${entry.text}\n${entry.detail ?? ''}`}>
              <span className="mono">{entry.text}</span>
              {entry.detail !== undefined && (
                <span className="muted small mono convention-detail" title={entry.detail}>
                  {entry.detail}
                </span>
              )}
              {convention.editable && (
                <button
                  className="link"
                  type="button"
                  aria-label={`Remove ${entry.text}`}
                  onClick={() => void remove(entry.text)}
                >
                  Remove
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
      {matching.length > shown.length && (
        <p className="muted small">
          Showing {shown.length} of {matching.length}. Filter to narrow the list.
        </p>
      )}
      {problem !== null && (
        <p className="error" role="alert">
          {problem}
        </p>
      )}
      {convention.editable ? (
        convention.id === 'projects' ? (
          <AddProjectForm onAdded={onChanged} />
        ) : (
          <AddEntryForm convention={convention} onAdded={onChanged} />
        )
      ) : (
        <p className="muted small">
          Its entries are structured, so they are changed in the file itself. The code graph checks
          them when it reads them.
        </p>
      )}
    </div>
  )
}

function ConventionCard({
  convention,
  open,
  onToggle,
  onChanged,
}: {
  convention: Convention
  open: boolean
  onToggle: (open: boolean) => void
  onChanged: () => void
}) {
  return (
    <details
      className="convention"
      open={open}
      onToggle={(event) => onToggle(event.currentTarget.open)}
    >
      <summary>
        <span className="convention-title">{convention.title}</span>
        <span className="muted small convention-about">{convention.about}</span>
        <span className="convention-count" aria-label={countLabel(convention.entries.length)}>
          {convention.entries.length}
        </span>
      </summary>
      {open && <ConventionBody convention={convention} onChanged={onChanged} />}
    </details>
  )
}

// The configuration files Synapse keeps, each a card that opens to its entries.
export function Conventions() {
  const load = useCallback(() => transport.listConventions(), [])
  const { state, reload } = useLoad(load)
  const [open, setOpen] = useState(readOpen)

  function toggle(id: string, isOpen: boolean) {
    setOpen((before) => {
      if (before.has(id) === isOpen) return before
      const next = new Set(before)
      if (isOpen) next.add(id)
      else next.delete(id)
      writeOpen(next)
      return next
    })
  }

  return (
    <div className="conventions">
      <p className="muted">
        What Synapse has learned or been told, kept in files on this machine. An agent writes most
        of it as it works, and a person can add an entry or take one out here.
      </p>
      {state.status === 'loading' && <p className="muted">Reading the files…</p>}
      {state.status === 'failed' && (
        <p role="alert" className="error">
          {state.error}
        </p>
      )}
      {state.status === 'ready' &&
        GROUPS.map((group) => {
          const cards = state.data.conventions.filter((c) => c.group === group)
          return (
            <section key={group} aria-label={group}>
              <h2 className="convention-group">{group}</h2>
              <div className="convention-cards">
                {cards.map((convention) => (
                  <ConventionCard
                    key={convention.id}
                    convention={convention}
                    open={open.has(convention.id)}
                    onToggle={(isOpen) => toggle(convention.id, isOpen)}
                    onChanged={reload}
                  />
                ))}
              </div>
            </section>
          )
        })}
    </div>
  )
}
