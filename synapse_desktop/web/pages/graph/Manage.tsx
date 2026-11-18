import { useState } from 'react'
import { dropQuestion, nothingToClean, removals } from '../../domain/graph-manage.ts'
import type { GraphPlan } from '../../../shared/transport.ts'
import { transport } from '../../transport/index.ts'
import { useConfig } from '../../state/config.tsx'
import { TERMINAL_LABELS, type TerminalKind, type TerminalTask } from '../../state/state.ts'
import { HarnessSelect, useHarness } from './harness.tsx'

// An action that changes a graph, which shows what it would do and asks first.
function Action({
  title,
  about,
  button,
  plan,
  run,
  question,
  confirm,
  nothing,
  onDone,
}: {
  title: string
  about: string
  button: string
  plan: () => Promise<GraphPlan>
  run: () => Promise<{ output: string }>
  question: (lines: string[]) => string
  confirm: string
  // Words for a plan that finds nothing to do, or null when there is always something.
  nothing: string | null
  onDone: () => void
}) {
  const [state, setState] = useState<
    | { status: 'idle' }
    | { status: 'planning' }
    | { status: 'asking'; lines: string[] }
    | { status: 'working' }
    | { status: 'done'; output: string }
    | { status: 'failed'; error: string }
  >({ status: 'idle' })

  async function ask() {
    setState({ status: 'planning' })
    try {
      setState({ status: 'asking', lines: (await plan()).lines })
    } catch (error) {
      setState({ status: 'failed', error: String(error) })
    }
  }

  async function go() {
    setState({ status: 'working' })
    try {
      setState({ status: 'done', output: (await run()).output })
      onDone()
    } catch (error) {
      setState({ status: 'failed', error: String(error) })
    }
  }

  const empty = state.status === 'asking' && nothing !== null && nothingToClean(state.lines)
  return (
    <section className="card" aria-label={title}>
      <h3 className="card-title">{title}</h3>
      <p className="muted small">{about}</p>
      <div className="row">
        <button
          className="secondary"
          disabled={state.status === 'planning' || state.status === 'working'}
          onClick={() => void ask()}
        >
          {state.status === 'planning' ? 'Looking…' : button}
        </button>
      </div>
      {state.status === 'asking' && empty && <p className="muted">{nothing}</p>}
      {state.status === 'asking' && !empty && (
        <div className="confirm" role="alertdialog" aria-label="Are you sure?">
          <p>
            <strong>Are you sure?</strong> {question(state.lines)}
          </p>
          <ul className="small">
            {removals(state.lines).map((path) => (
              <li key={path} className="mono">
                {path}
              </li>
            ))}
          </ul>
          <div className="row">
            <button className="primary" onClick={() => void go()}>
              {confirm}
            </button>
            <button className="secondary" onClick={() => setState({ status: 'idle' })}>
              Cancel
            </button>
          </div>
        </div>
      )}
      {state.status === 'working' && <p className="muted">Working…</p>}
      {state.status === 'done' && (
        <pre className="mono small" role="status">
          {state.output === '' ? 'Done.' : state.output}
        </pre>
      )}
      {state.status === 'failed' && <p role="alert">{state.error}</p>}
    </section>
  )
}

const REBUILDS: {
  task: TerminalTask
  title: string
  about: string
  button: string
  question: (ns: string) => string
}[] = [
  {
    task: 'rebuild-diff',
    title: 'Rebuild what changed',
    about:
      'Looks at what changed since each node was built and, node by node, reseats, patches or re-orients it. Nothing is deleted.',
    button: 'Rebuild what changed…',
    question: () =>
      'This opens a session in the repository that looks at what changed since each node was built and brings the nodes up to date.',
  },
  {
    task: 'rebuild-full',
    title: 'Rebuild from scratch',
    about:
      'Deletes the graph of this namespace, keeping the Notes written by hand, and builds it again.',
    button: 'Rebuild from scratch…',
    question: (ns) =>
      `This opens a session in the repository that deletes the graph of ${ns}, keeping the Notes written by hand, and builds it again from nothing.`,
  },
]

// Rebuilding a graph is an agent's work, so it opens a session of the default harness
// in the repository, with the command as its first prompt, where it can be watched
// and answered.
function Rebuild({
  namespace,
  repository,
  onStartTask,
}: {
  namespace: string
  repository: string
  onStartTask: (kind: TerminalKind, cwd: string, task: TerminalTask) => void
}) {
  const { harness, choose } = useHarness()
  const [asking, setAsking] = useState<TerminalTask | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function start(task: TerminalTask) {
    setError(null)
    const check = await transport.checkGraphRepo(repository).catch((e: unknown) => ({
      key: null,
      error: String(e),
    }))
    if (check.key !== namespace) {
      setError(
        check.key === null
          ? (check.error ?? 'That folder has no namespace.')
          : `${repository} is on ${check.key}, not ${namespace}, so a rebuild from it would build another graph.`,
      )
      return
    }
    setAsking(null)
    onStartTask(harness, repository, task)
  }

  return (
    <section className="card" aria-label="Rebuild">
      <h3 className="card-title">Rebuild with an agent</h3>
      <HarnessSelect label="Harness for the rebuild" harness={harness} onChange={choose} />
      {REBUILDS.map((rebuild) => (
        <div key={rebuild.task} className="rebuild">
          <p className="muted small">{rebuild.about}</p>
          <div className="row">
            <button className="secondary" onClick={() => setAsking(rebuild.task)}>
              {rebuild.button}
            </button>
          </div>
          {asking === rebuild.task && (
            <div className="confirm" role="alertdialog" aria-label="Are you sure?">
              <p>
                <strong>Are you sure?</strong> {rebuild.question(namespace)} It takes a while, uses{' '}
                {TERMINAL_LABELS[harness]}'s credits and will ask you things.
              </p>
              <div className="row">
                <button className="primary" onClick={() => void start(rebuild.task)}>
                  Yes, open {TERMINAL_LABELS[harness]}
                </button>
                <button className="secondary" onClick={() => setAsking(null)}>
                  Cancel
                </button>
              </div>
            </div>
          )}
        </div>
      ))}
      {error !== null && <p role="alert">{error}</p>}
    </section>
  )
}

// Changing a graph: rebuilding it, deleting it, and cleaning up the graphs of branches that are gone.
export function Manage({
  namespace,
  onChanged,
  onStartTask,
}: {
  namespace: string
  onChanged: () => void
  onStartTask: (kind: TerminalKind, cwd: string, task: TerminalTask) => void
}) {
  const { state: config } = useConfig()
  const saved = config.status === 'ready' ? (config.config.graphRepos[namespace] ?? null) : null
  if (saved === null) {
    return <p className="muted">Save the folder of the repository above to change this graph.</p>
  }
  return (
    <>
      <Rebuild namespace={namespace} repository={saved} onStartTask={onStartTask} />
      <Action
        title="Delete this graph"
        about="Removes the graph of this namespace from the vault, keeping the Notes written by hand in its nodes. Rebuild it afterwards from the repository."
        button="Delete the graph…"
        plan={() => transport.planGraphDrop(namespace)}
        run={() => transport.dropGraph(namespace)}
        question={(lines) => dropQuestion(namespace, lines)}
        confirm="Yes, delete the graph"
        nothing={null}
        onDone={onChanged}
      />
      <Action
        title="Clean up deleted branches"
        about="Removes the graphs of this repository whose branch is gone upstream."
        button="Look for graphs to clean up…"
        plan={() => transport.planGraphClean(namespace)}
        run={() => transport.cleanGraphs(namespace)}
        question={() => 'This removes these graphs from the vault.'}
        confirm="Yes, clean them up"
        nothing="Nothing to clean up: no graph of this repository is for a branch that is gone."
        onDone={onChanged}
      />
    </>
  )
}
