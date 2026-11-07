import { useCallback, useState } from 'react'
import { transport } from '../transport/index.ts'
import { useLoad } from './useLoad.ts'
import { DefinitionEditorPage } from './DefinitionEditorPage.tsx'
import { DefinitionPage } from './DefinitionPage.tsx'
import { ExecutionPage } from './ExecutionPage.tsx'
import { HomePage } from './HomePage.tsx'
import { PipelinePage } from './PipelinePage.tsx'
import { SettingsPage } from './SettingsPages.tsx'
import type { Page } from './state.ts'

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
    case 'home':
      return <HomePage onOpen={onOpen} />
    case 'settings':
      return <SettingsPage section={page.section} onChanged={onChanged} />
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
    // The terminals are kept by the shell, which does not unmount them.
    case 'terminals':
      return null
  }
}
