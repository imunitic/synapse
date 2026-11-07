import { useState } from 'react'
import { isEnvName, withoutVariable, withVariable } from '../domain/vaults.ts'
import { useConfig } from './config.tsx'

// Variables the app sets for every process it starts, over those it was started
// with. They are the app's own and are not written to synapse.conf.
export function EnvCard({
  onChanged,
  start,
}: {
  onChanged: () => void
  // A variable to begin the form with.
  start?: { name: string; value: string }
}) {
  const { state, save } = useConfig()
  const [name, setName] = useState(start?.name ?? '')
  const [value, setValue] = useState(start?.value ?? '')
  const [failure, setFailure] = useState<string | null>(null)
  if (state.status !== 'ready') return null
  const env = state.config.env
  const entries = Object.entries(env)

  async function change(next: Record<string, string>) {
    try {
      await save({ env: next })
      setFailure(null)
      onChanged()
    } catch (error) {
      setFailure(String(error))
    }
  }

  async function add(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!isEnvName(name)) {
      setFailure(
        'A variable name has letters, digits and underscores and does not start with a digit.',
      )
      return
    }
    await change(withVariable(env, name, value))
    setName('')
    setValue('')
  }

  return (
    <section className="card" aria-label="Environment">
      <h2 className="card-title">Environment</h2>
      <p className="muted small">
        Variables set for every command the app runs and every run it starts, over the environment
        the app was started in. They belong to the app and are not written to synapse.conf.
      </p>
      {entries.length === 0 && <p className="muted">None are set.</p>}
      <ul className="env-list">
        {entries.map(([key, val]) => (
          <li key={key} className="env-row">
            <span className="mono env-name">{key}</span>
            <span className="mono env-value">{val === '' ? '(empty)' : val}</span>
            <button className="link" onClick={() => void change(withoutVariable(env, key))}>
              Remove
            </button>
          </li>
        ))}
      </ul>
      <form className="row env-add" onSubmit={(event) => void add(event)}>
        <input
          className="mono"
          aria-label="Variable name"
          placeholder="NAME"
          value={name}
          onChange={(event) => setName(event.target.value)}
        />
        <input
          className="mono"
          aria-label="Variable value"
          placeholder="value"
          value={value}
          onChange={(event) => setValue(event.target.value)}
        />
        <button type="submit" className="secondary" disabled={name === ''}>
          Set
        </button>
      </form>
      {failure !== null && (
        <p className="error" role="alert">
          {failure}
        </p>
      )}
    </section>
  )
}
