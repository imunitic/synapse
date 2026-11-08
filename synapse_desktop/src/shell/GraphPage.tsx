import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  filterPaths,
  findSymbol,
  listCoveredPaths,
  listGraphs,
  listNodes,
  listUnassigned,
  nodeNotePath,
  ownersOf,
  type Graph,
  type SymbolHit,
} from '../domain/graph-search.ts'
import { findingsOf, nodesNeedingAttention, splitReason } from '../domain/graph-health.ts'
import type { GraphCheck, GraphFinding } from '../../shared/transport.ts'
import { dropQuestion, nothingToClean, removals } from '../domain/graph-manage.ts'
import type { GraphPlan } from '../../shared/transport.ts'
import { transport } from '../transport/index.ts'
import { useConfig } from './config.tsx'
import { useHarnesses } from './diagnosis.tsx'
import { TERMINAL_LABELS, type Page, type TerminalKind, type TerminalTask } from './state.ts'
import { useLoad } from './useLoad.ts'

type Mode = 'symbol' | 'files' | 'nodes' | 'health' | 'manage'

const NAMESPACE_KEY = 'synapse-desktop.graph-namespace'
const MAX_ROWS = 300

function remembered(): string | null {
  try {
    return localStorage.getItem(NAMESPACE_KEY)
  } catch {
    return null
  }
}

export function remember(namespace: string): void {
  try {
    localStorage.setItem(NAMESPACE_KEY, namespace)
  } catch {
    // The choice is only a convenience.
  }
}

// What a mode needs a namespace to have, or null when it has it.
function missing(graph: Graph, mode: Mode): string | null {
  // Managing a graph works on the repository saved for it, which any namespace can have.
  if (mode === 'manage') return null
  // Health reads the nodes and compares them with the repository's files.
  if (mode === 'health') {
    return graph.hasIndex
      ? null
      : 'This namespace has no node index here, so there is nothing to check.'
  }
  if (mode === 'symbol') {
    return graph.hasRefs
      ? null
      : 'This namespace has no reference index, so symbols cannot be searched.'
  }
  return graph.hasIndex
    ? null
    : 'This namespace has no node index, so it has no nodes or covered files here.'
}

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

function SymbolSearch({ namespace }: { namespace: string }) {
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
      <form className="row" role="search" onSubmit={(event) => void search(event)}>
        <input
          className="mono grow"
          aria-label="Symbol name"
          placeholder="An exact name, such as Work_Dir"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
        <label className="check small">
          <input type="checkbox" checked={all} onChange={(event) => setAll(event.target.checked)} />
          Definitions and every reference
        </label>
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

function FileSearch({ namespace, onOpen }: { namespace: string; onOpen: (page: Page) => void }) {
  const load = useCallback(() => listCoveredPaths(transport, namespace), [namespace])
  const { state: paths } = useLoad(load)
  const [query, setQuery] = useState('')
  const [chosen, setChosen] = useState<string | null>(null)
  const loadOwners = useCallback(
    () => (chosen === null ? Promise.resolve([]) : ownersOf(transport, namespace, chosen)),
    [namespace, chosen],
  )
  const { state: owners } = useLoad(loadOwners)
  const matches = useMemo(
    () => (paths.status === 'ready' ? filterPaths(paths.data, query, 100) : []),
    [paths, query],
  )

  return (
    <>
      <input
        className="mono"
        aria-label="File path"
        placeholder={
          paths.status === 'ready'
            ? `Words of a path, among ${paths.data.length} files`
            : 'Words of a path'
        }
        value={query}
        onChange={(event) => setQuery(event.target.value)}
      />
      {paths.status === 'loading' && <p className="muted">Loading the files…</p>}
      {paths.status === 'failed' && <p role="alert">{paths.error}</p>}
      {paths.status === 'ready' && query.trim() !== '' && matches.length === 0 && (
        <p className="muted">No covered file has those words.</p>
      )}
      <ul className="hits">
        {matches.map((path) => (
          <li key={path}>
            <button
              className="attention-item attention-link"
              aria-pressed={chosen === path}
              onClick={() => setChosen(path)}
            >
              <span className="mono small">{path}</span>
            </button>
          </li>
        ))}
      </ul>
      {chosen !== null && (
        <section className="card" aria-label="Owners">
          <h3 className="card-title">
            <span className="mono">{chosen}</span> is covered by
          </h3>
          {owners.status === 'loading' && <p className="muted">Looking…</p>}
          {owners.status === 'failed' && <p role="alert">{owners.error}</p>}
          {owners.status === 'ready' && owners.data.length === 0 && (
            <p className="muted">No node claims it.</p>
          )}
          {owners.status === 'ready' &&
            owners.data.map((node) => (
              <button
                key={node}
                className="attention-item attention-link"
                onClick={() => onOpen({ kind: 'note', path: nodeNotePath(namespace, node) })}
              >
                <span className="attention-label">{node.replace(/\.md$/, '')}</span>
              </button>
            ))}
        </section>
      )}
    </>
  )
}

function Nodes({ namespace, onOpen }: { namespace: string; onOpen: (page: Page) => void }) {
  const loadNodes = useCallback(() => listNodes(transport, namespace), [namespace])
  const loadUnassigned = useCallback(() => listUnassigned(transport, namespace), [namespace])
  const { state: nodes } = useLoad(loadNodes)
  const { state: unassigned } = useLoad(loadUnassigned)

  return (
    <>
      {nodes.status === 'loading' && <p className="muted">Loading…</p>}
      {nodes.status === 'failed' && <p role="alert">{nodes.error}</p>}
      {nodes.status === 'ready' && (
        <section aria-label="Nodes">
          <h3 className="attention-title">
            Nodes<span className="count-pill">{nodes.data.length}</span>
          </h3>
          <ul className="attention-list">
            {nodes.data.map((node) => (
              <li key={node}>
                <button
                  className="attention-item attention-link"
                  onClick={() => onOpen({ kind: 'note', path: nodeNotePath(namespace, node) })}
                >
                  <span className="attention-label">{node.replace(/\.md$/, '')}</span>
                </button>
              </li>
            ))}
          </ul>
        </section>
      )}
      {unassigned.status === 'ready' && unassigned.data.length > 0 && (
        <details className="card" aria-label="Unassigned files">
          <summary>
            {unassigned.data.length} {unassigned.data.length === 1 ? 'file is' : 'files are'}{' '}
            claimed by no node
          </summary>
          <ul className="hits">
            {unassigned.data.slice(0, MAX_ROWS).map((path) => (
              <li key={path} className="mono small">
                {path}
              </li>
            ))}
          </ul>
        </details>
      )}
    </>
  )
}

const MODES: { mode: Mode; label: string }[] = [
  { mode: 'symbol', label: 'Symbol' },
  { mode: 'files', label: 'Files' },
  { mode: 'nodes', label: 'Nodes' },
  { mode: 'health', label: 'Health' },
  { mode: 'manage', label: 'Manage' },
]

// The folder of the repository a graph was built from, which its health is read
// against. The folder is checked when it is saved and shown with the branch it is
// on, since a checkout of another branch makes every node look stale.
function RepoRow({ namespace }: { namespace: string }) {
  const { state: config, save } = useConfig()
  const saved = config.status === 'ready' ? (config.config.graphRepos[namespace] ?? null) : null
  const [draft, setDraft] = useState('')
  const [editing, setEditing] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const loadCheck = useCallback(
    () => (saved === null ? Promise.resolve(null) : transport.checkGraphRepo(saved)),
    [saved],
  )
  const { state: check } = useLoad(loadCheck)
  // Looked for when there is no folder, or the one saved is on another branch.
  const wrongBranch =
    check.status === 'ready' && check.data?.key != null && check.data.key !== namespace
  const looking = saved === null || wrongBranch
  const loadFound = useCallback(
    () => (looking ? transport.findGraphRepos(namespace) : Promise.resolve({ paths: [] })),
    [looking, namespace],
  )
  const { state: found } = useLoad(loadFound)
  const suggested =
    found.status === 'ready' ? found.data.paths.filter((path) => path !== saved) : []

  async function put(repos: Record<string, string>) {
    try {
      await save({ graphRepos: repos })
      setMessage(null)
      setEditing(false)
    } catch (error) {
      setMessage(`Not saved: ${String(error)}`)
    }
  }

  async function submit(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    const path = draft.trim()
    if (path === '' || config.status !== 'ready') return
    const result = await transport.checkGraphRepo(path).catch((error: unknown) => ({
      key: null,
      error: String(error),
    }))
    if (result.key === null) {
      setMessage(result.error ?? 'That folder has no namespace.')
      return
    }
    await put({ ...config.config.graphRepos, [namespace]: path })
  }

  if (config.status !== 'ready') return null
  const suggestions = suggested.length > 0 && (
    <div className="repo-suggest bar-note small" aria-label="Checkouts found">
      <span className="muted">
        {suggested.length === 1 ? 'A checkout' : 'Checkouts'} of {namespace} found:
      </span>
      {suggested.map((path) => (
        <span key={path} className="repo-suggestion">
          <span className="mono">{path}</span>
          <button
            className="link"
            onClick={() => void put({ ...config.config.graphRepos, [namespace]: path })}
          >
            Use it
          </button>
        </span>
      ))}
    </div>
  )
  if (saved !== null && !editing) {
    const other = wrongBranch
    return (
      <>
        <span className="muted small">Repository</span>
        <div className="repo-row" aria-label="Repository">
          <span className="mono small">{saved}</span>
          {check.status === 'ready' && check.data?.key != null && (
            <span className={other ? 'repo-warning small' : 'muted small'}>
              {other
                ? `is on ${check.data.key}, not ${namespace}, so every node may look stale`
                : `on ${check.data.key}`}
            </span>
          )}
          {check.status === 'ready' && check.data?.key == null && check.data?.error != null && (
            <span className="repo-warning small">{check.data.error}</span>
          )}
          <button
            className="link"
            onClick={() => {
              setDraft(saved)
              setEditing(true)
            }}
          >
            Change
          </button>
          <button
            className="link"
            onClick={() => {
              const rest = { ...config.config.graphRepos }
              delete rest[namespace]
              void put(rest)
            }}
          >
            Remove
          </button>
        </div>
        {suggestions}
      </>
    )
  }
  return (
    <>
      <span className="muted small">Repository</span>
      <form className="repo-row" aria-label="Repository" onSubmit={(event) => void submit(event)}>
        <input
          className="mono grow"
          aria-label="Repository folder"
          placeholder="/path/to/the/repository this graph was built from"
          value={draft}
          onChange={(event) => {
            setDraft(event.target.value)
            setMessage(null)
          }}
        />
        <button type="submit" className="secondary" disabled={draft.trim() === ''}>
          Save
        </button>
        {editing && (
          <button type="button" className="link" onClick={() => setEditing(false)}>
            Cancel
          </button>
        )}
        {message !== null && (
          <span role="alert" className="repo-warning small">
            {message}
          </span>
        )}
      </form>
      {suggestions}
    </>
  )
}

// A node's finding, which opens the node, with the files it lists kept closed.
function FindingLink({
  namespace,
  finding,
  onOpen,
}: {
  namespace: string
  finding: GraphFinding
  onOpen: (page: Page) => void
}) {
  const reason = splitReason(finding.reason)
  return (
    <>
      <button
        className="attention-item attention-link"
        onClick={() => onOpen({ kind: 'note', path: nodeNotePath(namespace, finding.node) })}
      >
        <span className="attention-label">{finding.node}</span>
        <span className="muted small attention-detail">{reason.text}</span>
      </button>
      {reason.items.length > 0 && (
        <details className="reason-files">
          <summary className="muted small">Show the {reason.items.length} files</summary>
          <ul className="mono small">
            {reason.items.map((file) => (
              <li key={file}>{file}</li>
            ))}
          </ul>
        </details>
      )}
    </>
  )
}

function Check({
  title,
  check,
  namespace,
  onOpen,
  about,
}: {
  title: string
  check: GraphCheck
  namespace: string
  onOpen: (page: Page) => void
  about: string
}) {
  const findings = findingsOf(check)
  return (
    <section className="card" aria-label={title}>
      <h3 className="card-title">
        {title}
        {check.ok && <span className="count-pill">{findings.length}</span>}
      </h3>
      <p className="muted small">{about}</p>
      {!check.ok && <p role="alert">Could not run: {check.error}</p>}
      {check.ok && findings.length === 0 && <p className="muted">None.</p>}
      <ul className="attention-list">
        {findings.map((finding, i) => (
          <li key={i}>
            {finding.node === '(repo)' ? (
              <div className="attention-item">
                <span className="attention-label">The repository</span>
                <span className="muted small attention-detail">{finding.reason}</span>
              </div>
            ) : (
              <FindingLink namespace={namespace} finding={finding} onOpen={onOpen} />
            )}
          </li>
        ))}
      </ul>
    </section>
  )
}

// How a graph stands against the repository saved for it.
function Health({ namespace, onOpen }: { namespace: string; onOpen: (page: Page) => void }) {
  const { state: config } = useConfig()
  const saved = config.status === 'ready' ? (config.config.graphRepos[namespace] ?? null) : null
  // Read again when a folder is saved, since the checks need one.
  const load = useCallback(
    () =>
      saved === null
        ? Promise.reject(new Error('no repository'))
        : transport.graphHealth(namespace),
    [namespace, saved],
  )
  const { state, reload } = useLoad(load)
  if (saved === null) {
    return (
      <p className="muted">
        Save the folder of the repository above to check this graph against it.
      </p>
    )
  }
  if (state.status === 'loading')
    return <p className="muted">Checking the graph against the files…</p>
  if (state.status === 'failed') return <p role="alert">Could not check: {state.error}</p>
  const attention = nodesNeedingAttention(state.data)
  return (
    <>
      <div className="row">
        <p className="muted">
          {attention.length === 0
            ? 'No node needs attention.'
            : `${attention.length} ${attention.length === 1 ? 'node needs' : 'nodes need'} attention.`}
        </p>
        <button className="link" onClick={reload}>
          Check again
        </button>
      </div>
      <Check
        title="Stale nodes"
        check={state.data.stale}
        namespace={namespace}
        onOpen={onOpen}
        about="Their files no longer match what they were written from."
      />
      <Check
        title="Drift"
        check={state.data.drift}
        namespace={namespace}
        onOpen={onOpen}
        about="What changed since the commit each node was built at."
      />
      <Check
        title="Not grounded"
        check={state.data.grounding}
        namespace={namespace}
        onOpen={onOpen}
        about="Their evidence no longer matches the files."
      />
    </>
  )
}

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

// The harness a graph is built with: the one chosen here, else the default.
function useHarness(): { harness: TerminalKind; choose: (kind: TerminalKind) => void } {
  const { defaultHarness } = useHarnesses()
  const [chosen, setChosen] = useState<TerminalKind | null>(null)
  return { harness: chosen ?? defaultHarness, choose: setChosen }
}

function HarnessSelect({
  label,
  harness,
  onChange,
}: {
  label: string
  harness: TerminalKind
  onChange: (kind: TerminalKind) => void
}) {
  const harnesses = useHarnesses()
  return (
    <label className="field">
      <span className="muted small">Harness</span>
      <select
        aria-label={label}
        value={harness}
        onChange={(event) => onChange(event.target.value as TerminalKind)}
      >
        {(['Claude', 'Codex', 'Opencode'] as const).map((kind) => (
          <option key={kind} value={kind} disabled={harnesses.isMissing(kind)}>
            {TERMINAL_LABELS[kind]}
            {harnesses.isMissing(kind) ? ' (not installed)' : ''}
          </option>
        ))}
      </select>
    </label>
  )
}

// A graph that does not exist yet is built from a repository folder: the folder is
// checked for the namespace it is on, which is the graph's name, and an agent builds
// it with the first-build command in that folder.
function NewGraph({
  existing,
  onSelect,
  onStartTask,
  onClose,
}: {
  existing: readonly string[]
  onSelect: (namespace: string) => void
  onStartTask: (kind: TerminalKind, cwd: string, task: TerminalTask) => void
  onClose: () => void
}) {
  const { state: config, save } = useConfig()
  const { harness, choose } = useHarness()
  const [draft, setDraft] = useState('')
  const [found, setFound] = useState<{ path: string; key: string } | null>(null)
  const [error, setError] = useState<string | null>(null)

  const close = onClose

  async function check(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    const path = draft.trim()
    if (path === '') return
    setFound(null)
    const result = await transport.checkGraphRepo(path).catch((e: unknown) => ({
      key: null,
      error: String(e),
    }))
    if (result.key === null) {
      setError(result.error ?? 'That folder has no namespace.')
      return
    }
    setError(null)
    setFound({ path, key: result.key })
  }

  async function build(path: string, key: string) {
    if (config.status !== 'ready') return
    try {
      await save({ graphRepos: { ...config.config.graphRepos, [key]: path } })
    } catch (e) {
      setError(`Not saved: ${String(e)}`)
      return
    }
    onStartTask(harness, path, 'init')
    close()
  }

  const exists = found !== null && existing.includes(found.key)
  return (
    <section className="card" aria-label="New graph">
      <h3 className="card-title">New graph</h3>
      <form className="row" onSubmit={(event) => void check(event)}>
        <input
          className="grow"
          aria-label="Folder of the repository to build from"
          placeholder="/path/to/the/repository"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
        <button className="secondary" type="submit" disabled={draft.trim() === ''}>
          Check
        </button>
        <button className="link" type="button" onClick={close}>
          Cancel
        </button>
      </form>
      {error !== null && <p role="alert">{error}</p>}
      {found !== null && exists && (
        <p>
          {found.key} already has a graph. Rebuild it from its Manage tab.{' '}
          <button
            className="link"
            onClick={() => {
              onSelect(found.key)
              close()
            }}
          >
            Open it
          </button>
        </p>
      )}
      {found !== null && !exists && (
        <div className="confirm" role="alertdialog" aria-label="Are you sure?">
          <p>
            <strong>Are you sure?</strong> This opens a session in {found.path} that builds the
            first graph of {found.key}. It takes a while, uses {TERMINAL_LABELS[harness]}'s credits
            and will ask you things.
          </p>
          <HarnessSelect label="Harness for the new graph" harness={harness} onChange={choose} />
          <div className="row">
            <button className="primary" onClick={() => void build(found.path, found.key)}>
              Yes, open {TERMINAL_LABELS[harness]}
            </button>
            <button className="secondary" onClick={close}>
              Cancel
            </button>
          </div>
        </div>
      )}
    </section>
  )
}

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
function Manage({
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

// Searching what a code graph keeps locally: its symbols, the files its nodes
// cover and the nodes themselves, for the namespace chosen. The nodes' notes are
// in the vault, which is where a node opens.
export function GraphPage({
  onOpen,
  onStartTask,
}: {
  onOpen: (page: Page) => void
  onStartTask: (kind: TerminalKind, cwd: string, task: TerminalTask) => void
}) {
  const loadGraphs = useCallback(() => listGraphs(transport), [])
  const { state: graphs, reload } = useLoad(loadGraphs)
  const [chosen, setChosen] = useState<string | null>(remembered())
  const [mode, setMode] = useState<Mode>('symbol')
  const [building, setBuilding] = useState(false)

  const list = graphs.status === 'ready' ? graphs.data : []
  const graph = list.find((g) => g.namespace === chosen) ?? list[0]

  // A mode the namespace cannot serve gives way to one it can.
  useEffect(() => {
    if (graph === undefined) return
    if (missing(graph, mode) === null) return
    const next = MODES.find((m) => missing(graph, m.mode) === null)
    if (next !== undefined) setMode(next.mode)
  }, [graph, mode])

  return (
    <div className="page wide graph-page">
      <div className="graph-head">
        <h1 className="page-title">Code graph</h1>
        <button className="secondary" disabled={building} onClick={() => setBuilding(true)}>
          New graph…
        </button>
      </div>
      {building && (
        <NewGraph
          existing={list.map((g) => g.namespace)}
          onSelect={(namespace) => {
            setChosen(namespace)
            remember(namespace)
          }}
          onStartTask={onStartTask}
          onClose={() => setBuilding(false)}
        />
      )}
      {graphs.status === 'loading' && <p className="muted">Looking for graphs…</p>}
      {graphs.status === 'failed' && <p role="alert">Could not look for graphs: {graphs.error}</p>}
      {graphs.status === 'ready' && list.length === 0 && (
        <p className="muted">
          No graph has local files yet. Build one from a repository with New graph, and it shows
          here.
        </p>
      )}
      {graph !== undefined && (
        <>
          <div className="graph-bar">
            <span className="muted small">Namespace</span>
            <div className="row graph-controls">
              <select
                aria-label="Namespace"
                value={graph.namespace}
                onChange={(event) => {
                  setChosen(event.target.value)
                  remember(event.target.value)
                }}
              >
                {list.map((g) => (
                  <option key={g.namespace} value={g.namespace}>
                    {g.namespace}
                  </option>
                ))}
              </select>
              <span className="muted small">
                has{' '}
                {[
                  graph.hasIndex && 'a node index',
                  graph.hasRefs && 'references',
                  graph.hasTags && 'tags',
                ]
                  .filter(Boolean)
                  .join(', ')}
              </span>
              <button className="link" onClick={reload}>
                Look again
              </button>
            </div>
            <RepoRow namespace={graph.namespace} />
          </div>
          <div className="subtabs graph-tabs" role="tablist" aria-label="What to search">
            {MODES.map(({ mode: m, label }) => (
              <button
                key={m}
                className="subtab"
                role="tab"
                aria-selected={mode === m}
                aria-pressed={mode === m}
                disabled={missing(graph, m) !== null}
                title={missing(graph, m) ?? undefined}
                onClick={() => setMode(m)}
              >
                {label}
              </button>
            ))}
          </div>
          {missing(graph, mode) !== null ? (
            <p className="muted">{missing(graph, mode)}</p>
          ) : (
            <div key={`${graph.namespace}:${mode}`} className="graph-body">
              {mode === 'symbol' && <SymbolSearch namespace={graph.namespace} />}
              {mode === 'files' && <FileSearch namespace={graph.namespace} onOpen={onOpen} />}
              {mode === 'nodes' && <Nodes namespace={graph.namespace} onOpen={onOpen} />}
              {mode === 'health' && <Health namespace={graph.namespace} onOpen={onOpen} />}
              {mode === 'manage' && (
                <Manage namespace={graph.namespace} onChanged={reload} onStartTask={onStartTask} />
              )}
            </div>
          )}
        </>
      )}
    </div>
  )
}
