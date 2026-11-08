import { useState } from 'react'
import { findSymbol, type SymbolHit } from '../../domain/graph-search.ts'
import { transport } from '../../transport/index.ts'
import { MAX_ROWS } from './rows.ts'

// The two searches there are: the calls of a name, or where it is defined and everything that
// refers to it.
const WAYS: { all: boolean; label: string; about: string }[] = [
  { all: false, label: 'Calls', about: 'Where the name is called.' },
  {
    all: true,
    label: 'Definitions and references',
    about: 'Where the name is defined, and every place that refers to it.',
  },
]

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

export function SymbolSearch({ namespace }: { namespace: string }) {
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
      <div className="way">
        <div className="subtabs graph-tabs" role="radiogroup" aria-label="What to find">
          {WAYS.map(({ all: way, label }) => (
            <button
              key={label}
              className="subtab"
              role="radio"
              aria-checked={all === way}
              aria-pressed={all === way}
              onClick={() => setAll(way)}
            >
              {label}
            </button>
          ))}
        </div>
        <p className="muted small">{WAYS.find((w) => w.all === all)?.about}</p>
      </div>
      <form className="row" role="search" onSubmit={(event) => void search(event)}>
        <input
          className="mono grow"
          aria-label="Symbol name"
          placeholder="An exact name, such as Work_Dir"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
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
