import { useState } from 'react'
import { useConfig } from './config.tsx'
import { DEFINITION_LABELS, type Page } from './state.ts'

function WorkDirectoryForm({ initial }: { initial: string }) {
  const { save } = useConfig()
  const [draft, setDraft] = useState(initial)
  const [message, setMessage] = useState<string | null>(null)

  async function submit(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    try {
      const trimmed = draft.trim()
      await save({ workDir: trimmed === '' ? null : trimmed })
      setMessage('Saved.')
    } catch (error) {
      setMessage(`Not saved: ${String(error)}`)
    }
  }

  return (
    <form className="card" onSubmit={(event) => void submit(event)}>
      <h2 className="card-title">Work directory</h2>
      <p id="work-dir-hint" className="muted">
        Where runs keep their records. A run started without one cannot be seen here.
      </p>
      <input
        aria-label="Work directory path"
        aria-describedby="work-dir-hint"
        className="mono"
        value={draft}
        placeholder="/path/to/work-directory"
        onChange={(event) => {
          setDraft(event.target.value)
          setMessage(null)
        }}
      />
      <div className="row">
        <button type="submit" className="primary">
          Save
        </button>
        {message !== null && <span role="status">{message}</span>}
      </div>
    </form>
  )
}

function SettingsPage() {
  const { state } = useConfig()
  return (
    <div className="page">
      <h1 className="page-title">Settings</h1>
      {state.status === 'loading' && <p className="muted">Loading…</p>}
      {state.status === 'failed' && <p role="alert">The server did not answer: {state.error}</p>}
      {state.status === 'ready' && <WorkDirectoryForm initial={state.config.workDir ?? ''} />}
    </div>
  )
}

function CreatePage({ definition }: { definition: keyof typeof DEFINITION_LABELS }) {
  const labels = DEFINITION_LABELS[definition]
  return (
    <div className="page">
      <p className="eyebrow">Create</p>
      <h1 className="page-title">New {labels.singular}</h1>
      <div className="placeholder">The form for a new {labels.singular} is not designed yet.</div>
    </div>
  )
}

export function PageView({ page }: { page: Page }) {
  switch (page.kind) {
    case 'settings':
      return <SettingsPage />
    case 'create':
      return <CreatePage definition={page.definition} />
  }
}
