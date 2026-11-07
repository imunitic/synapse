import { useCallback, useState } from 'react'
import { transport } from '../transport/index.ts'
import { useLoad } from './useLoad.ts'
import { useConfig } from './config.tsx'
import { DefinitionEditorPage } from './DefinitionEditorPage.tsx'
import { loadSettings } from '../domain/settings.ts'
import { EnvCard } from './EnvCard.tsx'
import { SettingsForm } from './SettingsForm.tsx'
import { VaultCard } from './VaultCard.tsx'
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

// The settings of Synapse are read again after any change: a vault, a variable
// or a setting each show up in the others.
function SynapseSettings() {
  const [version, setVersion] = useState(0)
  const load = useCallback(() => loadSettings(transport), [])
  const { state } = useLoad(load, undefined, version)
  const changed = () => setVersion((v) => v + 1)

  if (state.status === 'loading') return <p className="muted">Loading the settings…</p>
  if (state.status === 'failed') {
    return <p role="alert">Could not read the settings of Synapse: {state.error}</p>
  }
  return (
    <>
      <VaultCard
        vault={state.data.settings.find((s) => s.key === 'SYNAPSE_VAULT_DIR')}
        onChanged={changed}
      />
      <EnvCard onChanged={changed} />
      <SettingsForm settings={state.data} onChanged={changed} />
    </>
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
      <SynapseSettings />
    </div>
  )
}

// A definition's page, which turns into its editor while it is edited. After a
// save the page is read again.
function DefinitionView({
  page,
  onOpen,
  onChanged,
}: {
  page: Extract<Page, { kind: 'definition' }>
  onOpen: (page: Page) => void
  onChanged: () => void
}) {
  const [editing, setEditing] = useState(false)
  const [version, setVersion] = useState(0)
  const read = useCallback(() => transport.readText(page.path), [page.path])
  // Read again after a save.
  const { state } = useLoad(read, undefined, version)

  if (editing) {
    if (state.status === 'loading') return <p className="muted">Loading…</p>
    if (state.status === 'failed') return <p role="alert">Could not read the file: {state.error}</p>
    return (
      <DefinitionEditorPage
        definition={page.definition}
        existing={{ name: page.name, path: page.path, text: state.data }}
        onCreated={onOpen}
        onSaved={() => {
          setEditing(false)
          setVersion((v) => v + 1)
          onChanged()
        }}
        onCancel={() => setEditing(false)}
      />
    )
  }
  const edit = () => setEditing(true)
  return page.definition === 'pipeline' ? (
    <PipelinePage key={version} name={page.name} path={page.path} onOpen={onOpen} onEdit={edit} />
  ) : (
    <DefinitionPage
      key={version}
      definition={page.definition}
      name={page.name}
      path={page.path}
      onOpen={onOpen}
      onEdit={edit}
    />
  )
}

export function PageView({
  page,
  onOpen,
  onCreated,
  onChanged,
  onCancel,
}: {
  page: Page
  onOpen: (page: Page) => void
  // A definition was made; this is its page.
  onCreated: (page: Page) => void
  // A definition was changed.
  onChanged: () => void
  onCancel: () => void
}) {
  switch (page.kind) {
    case 'settings':
      return <SettingsPage />
    case 'create':
      return (
        <DefinitionEditorPage
          definition={page.definition}
          onCreated={onCreated}
          onSaved={onChanged}
          onCancel={onCancel}
        />
      )
    case 'definition':
      return <DefinitionView page={page} onOpen={onOpen} onChanged={onChanged} />
    case 'execution':
      return <ExecutionPage id={page.id} />
  }
}
