import { useState } from 'react'
import { useConfig } from './config.tsx'
import { CreatePage } from './CreatePage.tsx'
import { DefinitionPage } from './DefinitionPage.tsx'
import { ExecutionPage } from './ExecutionPage.tsx'
import { PipelinePage } from './PipelinePage.tsx'
import type { Page } from './state.ts'

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

export function PageView({
  page,
  onOpen,
  onCreated,
  onCancel,
}: {
  page: Page
  onOpen: (page: Page) => void
  // A definition was made; this is its page.
  onCreated: (page: Page) => void
  onCancel: () => void
}) {
  switch (page.kind) {
    case 'settings':
      return <SettingsPage />
    case 'create':
      return <CreatePage definition={page.definition} onCreated={onCreated} onCancel={onCancel} />
    case 'definition':
      return page.definition === 'pipeline' ? (
        <PipelinePage name={page.name} path={page.path} onOpen={onOpen} />
      ) : (
        <DefinitionPage
          definition={page.definition}
          name={page.name}
          path={page.path}
          onOpen={onOpen}
        />
      )
    case 'execution':
      return <ExecutionPage id={page.id} />
  }
}
