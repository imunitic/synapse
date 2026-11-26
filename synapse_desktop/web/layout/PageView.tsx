import { useCallback, useState } from 'react'
import { transport } from '../transport/index.ts'
import { useLoad } from '../state/useLoad.ts'
import { useWatch } from '../state/useWatch.ts'
import { DefinitionEditorPage } from '../pages/DefinitionEditorPage.tsx'
import { DefinitionPage } from '../pages/DefinitionPage.tsx'
import { ExecutionPage } from '../pages/ExecutionPage.tsx'
import { GraphPage } from '../pages/GraphPage.tsx'
import { LaunchPage } from '../pages/LaunchPage.tsx'
import { HomePage } from '../pages/HomePage.tsx'
import { NewNotePage } from '../pages/NewNotePage.tsx'
import { NotePage } from '../pages/NotePage.tsx'
import { RunStartingPage } from '../pages/RunStartingPage.tsx'
import { PipelinePage } from '../pages/PipelinePage.tsx'
import { VaultPage } from '../pages/VaultPage.tsx'
import { SettingsPage } from '../pages/SettingsPages.tsx'
import type { Activity } from '../domain/activity.ts'
import type { LiveSession } from '../domain/live.ts'
import type { Page, TerminalKind, TerminalSession, TerminalTask } from '../state/state.ts'

// A definition's page, which turns into its editor while it is edited. After a
// save the page is read again.
function DefinitionView({
  page,
  onOpen,
  onChanged,
  onStartRun,
}: {
  page: Extract<Page, { kind: 'definition' }>
  onOpen: (page: Page) => void
  onChanged: () => void
  onStartRun: (pipeline: string, input: unknown, folder: string) => void
}) {
  const [editing, setEditing] = useState(false)
  const [version, setVersion] = useState(0)
  const read = useCallback(() => transport.readText(page.path), [page.path])
  // Read again after a save.
  const { state, reload } = useLoad(read, undefined, version)
  // A definition changed on disk is read again, unless it is being edited.
  useWatch('definitions', () => {
    if (!editing) reload()
  })

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
    <PipelinePage
      key={version}
      name={page.name}
      path={page.path}
      onOpen={onOpen}
      onEdit={edit}
      onStartInteractive={(input, folder) => onStartRun(page.name, input, folder)}
    />
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
  onShowChanges,
  onStartTerminal,
  onStartTask,
  onStartIn,
  onRunCommand,
  onStartRun,
  onDismissRun,
  waiting,
  live,
  activity,
  onStopTerminal,
  onTerminalEnded,
  onTerminalClaimed,
  onTerminalRun,
}: {
  page: Page
  onOpen: (page: Page) => void
  // The home page shows the terminals that are open and can start one.
  terminals: readonly TerminalSession[]
  onSelectTerminal: (id: string) => void
  // The Changes sidebar is opened on a run's changes, at a file when one is named.
  onShowChanges: (path?: string) => void
  onStartTerminal: (kind: TerminalKind) => void
  // A harness is started in a folder for a task.
  onStartTask: (kind: TerminalKind, cwd: string, task: TerminalTask) => void
  // A terminal is started in a folder.
  onStartIn: (kind: TerminalKind, cwd: string, resume?: string) => void
  // A shell tab is opened, and runs the command; its tab is called the title.
  onRunCommand: (command: string, title: string) => void
  // An interactive run of a pipeline is started in the terminals, with this input.
  onStartRun: (pipeline: string, input: unknown, folder: string) => void
  // A run that did not start is let go: its session and its page.
  onDismissRun: (session: string) => void
  // What the agent of each interactive run that waits for a person said, by execution.
  waiting: ReadonlyMap<string, string>
  // The running session of this page's run and what it has done so far; the execution page shows them.
  live: LiveSession | null
  activity: Activity | null
  // The terminal of a run, shown on its page: closed, ended, held by the host, and named a run.
  onStopTerminal: (session: string) => void
  onTerminalEnded: (session: string) => void
  onTerminalClaimed: (session: string) => void
  onTerminalRun: (session: string, executionId: string) => void
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
    case 'vault':
      return <VaultPage onOpen={onOpen} />
    case 'definition':
      return (
        <DefinitionView page={page} onOpen={onOpen} onChanged={onChanged} onStartRun={onStartRun} />
      )
    case 'execution':
      return (
        <ExecutionPage
          id={page.id}
          terminals={terminals}
          waiting={waiting}
          live={live}
          activity={activity}
          onStopTerminal={onStopTerminal}
          onTerminalEnded={onTerminalEnded}
          onTerminalClaimed={onTerminalClaimed}
          onTerminalRun={onTerminalRun}
          onShowChanges={onShowChanges}
        />
      )
    case 'run-starting':
      return (
        <RunStartingPage
          session={terminals.find((t) => t.id === page.session)}
          onDismiss={() => onDismissRun(page.session)}
        />
      )
    // The terminals are kept by the shell, which does not unmount them.
    case 'terminals':
      return null
  }
}
