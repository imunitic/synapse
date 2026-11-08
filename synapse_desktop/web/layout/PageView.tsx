import { useCallback, useState } from 'react'
import { transport } from '../transport/index.ts'
import { useLoad } from '../state/useLoad.ts'
import { DefinitionEditorPage } from '../pages/DefinitionEditorPage.tsx'
import { DefinitionPage } from '../pages/DefinitionPage.tsx'
import { ExecutionPage } from '../pages/ExecutionPage.tsx'
import { GraphPage } from '../pages/GraphPage.tsx'
import { LaunchPage } from '../pages/LaunchPage.tsx'
import { HomePage } from '../pages/HomePage.tsx'
import { NewNotePage } from '../pages/NewNotePage.tsx'
import { NotePage } from '../pages/NotePage.tsx'
import { PipelinePage } from '../pages/PipelinePage.tsx'
import { SettingsPage } from '../pages/SettingsPages.tsx'
import type { Page, TerminalKind, TerminalSession, TerminalTask } from '../state/state.ts'

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
  terminals,
  onSelectTerminal,
  onStartTerminal,
  onStartTask,
  onStartIn,
  onRunCommand,
}: {
  page: Page
  onOpen: (page: Page) => void
  // The home page shows the terminals that are open and can start one.
  terminals: readonly TerminalSession[]
  onSelectTerminal: (id: string) => void
  onStartTerminal: (kind: TerminalKind) => void
  // A harness is started in a folder for a task.
  onStartTask: (kind: TerminalKind, cwd: string, task: TerminalTask) => void
  // A terminal is started in a folder.
  onStartIn: (kind: TerminalKind, cwd: string) => void
  // A shell tab is opened, and runs the command; its tab is called the title.
  onRunCommand: (command: string, title: string) => void
  // A definition was made; this is its page.
  onCreated: (page: Page) => void
  // A definition was changed.
  onChanged: () => void
  onCancel: () => void
}) {
  switch (page.kind) {
    case 'home':
      return (
        <HomePage
          onOpen={onOpen}
          terminals={terminals}
          onSelectTerminal={onSelectTerminal}
          onStartTerminal={onStartTerminal}
        />
      )
    case 'launch':
      return <LaunchPage onStart={onStartIn} />
    case 'graph':
      return <GraphPage onOpen={onOpen} onStartTask={onStartTask} />
    case 'note':
      return <NotePage key={page.path} path={page.path} onOpen={onOpen} />
    case 'settings':
      return (
        <SettingsPage section={page.section} onChanged={onChanged} onRunCommand={onRunCommand} />
      )
    case 'create':
      return (
        <DefinitionEditorPage
          definition={page.definition}
          onCreated={onCreated}
          onSaved={onChanged}
          onCancel={onCancel}
        />
      )
    case 'new-note':
      return <NewNotePage onCreated={onCreated} />
    case 'definition':
      return <DefinitionView page={page} onOpen={onOpen} onChanged={onChanged} />
    case 'execution':
      return <ExecutionPage id={page.id} />
    // The terminals are kept by the shell, which does not unmount them.
    case 'terminals':
      return null
  }
}
