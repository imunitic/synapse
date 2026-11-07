import { useCallback } from 'react'
import {
  attentionFailures,
  attentionGroups,
  isSettled,
  loadVaultAttention,
  type AttentionInputs,
  type AttentionItem,
  type AttentionTarget,
  type GraphLine,
  type Source,
  type VaultAttention,
} from '../domain/attention.ts'
import { listDefinitions } from '../domain/definitions.ts'
import { timeAgo } from '../domain/format.ts'
import { healthLine } from '../domain/graph-health.ts'
import { listGraphs } from '../domain/graph-search.ts'
import { recentlyUpdated, titleOf } from '../domain/notes.ts'
import { recentlyOpened } from '../domain/recent.ts'
import { listExecutions, type ExecutionSummary } from '../domain/executions.ts'
import { recentRuns, runCounts, setupSteps, vaultCounts } from '../domain/home.ts'
import { describeVault } from '../domain/vaults.ts'
import { transport } from '../transport/index.ts'
import { useConfig } from './config.tsx'
import { remember } from './GraphPage.tsx'
import { RefreshIcon } from './icons.tsx'
import type { Page, TerminalKind, TerminalSession } from './state.ts'
import { StatusBadge } from './StatusBadge.tsx'
import { useLoad, type LoadState } from './useLoad.ts'

const REFRESH_MS = 30_000

function asSource<T>(state: LoadState<T>): Source<T> {
  return state
}

function pageOf(target: AttentionTarget): Page {
  switch (target.kind) {
    case 'settings':
      return { kind: 'settings', section: target.section }
    case 'execution':
      return { kind: 'execution', id: target.id }
    case 'note':
      return { kind: 'note', path: target.path }
    case 'graph':
      remember(target.namespace)
      return { kind: 'graph' }
  }
}

function ItemRow({ item, onOpen }: { item: AttentionItem; onOpen: (page: Page) => void }) {
  const body = (
    <>
      <span className="attention-label">
        {item.id !== null && <span className="note-id">{item.id}</span>}
        {item.label}
      </span>
      {item.detail !== null && <span className="muted small attention-detail">{item.detail}</span>}
    </>
  )
  return (
    <li>
      {item.target === null ? (
        <div className="attention-item">{body}</div>
      ) : (
        <button
          className="attention-item attention-link"
          onClick={() => onOpen(pageOf(item.target as AttentionTarget))}
        >
          {body}
        </button>
      )}
    </li>
  )
}

// The things worth looking at: a harness that is broken, runs that went wrong
// and what the vault wants decided. A source that failed is said so, and the
// rest still show.
function NeedsAttention({
  inputs,
  onRefresh,
  onOpen,
}: {
  inputs: AttentionInputs
  onRefresh: () => void
  onOpen: (page: Page) => void
}) {
  const groups = attentionGroups(inputs)
  const failures = attentionFailures(inputs)
  const settled = isSettled(inputs)
  return (
    <section className="card" aria-label="Needs attention">
      <div className="card-head">
        <h2 className="card-title">Needs attention</h2>
        <button className="icon-button" aria-label="Refresh" onClick={onRefresh}>
          <RefreshIcon />
        </button>
      </div>
      {!settled && groups.length === 0 && <p className="muted">Looking…</p>}
      {settled && groups.length === 0 && failures.length === 0 && (
        <p className="muted">Nothing needs attention.</p>
      )}
      {groups.map((group) => (
        <div key={group.key} className="attention-group">
          <h3 className="attention-title">
            {group.title}
            <span className="count-pill">{group.items.length}</span>
          </h3>
          <ul className="attention-list">
            {group.items.map((item) => (
              <ItemRow key={item.key} item={item} onOpen={onOpen} />
            ))}
          </ul>
        </div>
      ))}
      {failures.map((failure) => (
        <p key={failure.source} role="alert" className="small">
          Could not read {failure.source}: {failure.error}
        </p>
      ))}
    </section>
  )
}

// Where to pick up: the notes opened in the app lately, and the notes the vault
// says were updated last.
function Continue({ onOpen }: { onOpen: (page: Page) => void }) {
  const loadUpdated = useCallback(() => recentlyUpdated(transport, 6), [])
  const updated = useLoad(loadUpdated, REFRESH_MS)
  const opened = recentlyOpened(5)
  const now = new Date()
  if (opened.length === 0 && updated.state.status !== 'ready') return null
  if (opened.length === 0 && updated.state.status === 'ready' && updated.state.data.length === 0) {
    return null
  }
  const open = (path: string) => onOpen({ kind: 'note', path })
  return (
    <section className="card" aria-label="Continue">
      <h2 className="card-title">Continue where you left off</h2>
      {opened.length > 0 && (
        <div className="attention-group">
          <h3 className="attention-title">Opened lately</h3>
          <ul className="attention-list">
            {opened.map((path) => (
              <li key={path}>
                <button className="attention-item attention-link" onClick={() => open(path)}>
                  <span className="attention-label">{titleOf(path)}</span>
                  <span className="muted small attention-detail">{path}</span>
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
      {updated.state.status === 'ready' && updated.state.data.length > 0 && (
        <div className="attention-group">
          <h3 className="attention-title">Updated lately</h3>
          <ul className="attention-list">
            {updated.state.data.map((note) => (
              <li key={note.path}>
                <button
                  className="attention-item attention-link run-row"
                  onClick={() => open(note.path)}
                >
                  <span className="attention-label">{note.title}</span>
                  <span className="muted small">{timeAgo(note.updated, now)}</span>
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  )
}

// What the app needs to be useful, while something of it is not done.
function SetupCard({ inputs, onOpen }: { inputs: AttentionInputs; onOpen: (page: Page) => void }) {
  const steps = setupSteps(inputs)
  if (steps.length === 0 || steps.every((step) => step.done)) return null
  return (
    <section className="card" aria-label="Get set up">
      <div className="card-head">
        <h2 className="card-title">Get set up</h2>
        <span className="muted small">
          {steps.filter((step) => step.done).length} of {steps.length} done
        </span>
      </div>
      <ul className="attention-list">
        {steps.map((step) => (
          <li key={step.key}>
            <button
              className="attention-item attention-link"
              disabled={step.done}
              onClick={() => onOpen({ kind: 'settings', section: step.target.section })}
            >
              <span className="step">
                <span className="step-mark" data-done={step.done} aria-hidden="true" />
                <span className="attention-label" data-done={step.done}>
                  {step.label}
                </span>
                <span className="visually-hidden">{step.done ? ' (done)' : ' (not done)'}</span>
              </span>
            </button>
          </li>
        ))}
      </ul>
    </section>
  )
}

// The vault at a glance: where it is, how many notes, and the counts of what
// waits for a decision.
function VaultSummary({
  vault,
  onOpen,
}: {
  vault: LoadState<VaultAttention>
  onOpen: (page: Page) => void
}) {
  const path = vault.status === 'ready' && vault.data.configured ? vault.data.vault : null
  const load = useCallback(
    () => (path === null ? Promise.resolve(null) : transport.inspectVault(path)),
    [path],
  )
  const { state: info } = useLoad(load)
  return (
    <section className="card" aria-label="Vault">
      <h2 className="card-title">Vault</h2>
      {vault.status === 'loading' && <p className="muted">Looking…</p>}
      {vault.status === 'failed' && <p className="muted">It could not be read.</p>}
      {vault.status === 'ready' && !vault.data.configured && (
        <p className="muted">
          No vault is chosen.{' '}
          <button className="link" onClick={() => onOpen({ kind: 'settings', section: 'vault' })}>
            Choose one
          </button>
        </p>
      )}
      {vault.status === 'ready' && vault.data.configured && (
        <>
          <p className="mono small">{vault.data.vault}</p>
          {info.status === 'ready' && info.data !== null && (
            <p className="muted small">{describeVault(info.data)}</p>
          )}
          <div className="tiles">
            {(
              [
                ['discussing', 'Discussing'],
                ['ready_uncompiled', 'Not compiled'],
                ['in_progress', 'In progress'],
                ['awaiting_review', 'In review'],
              ] as const
            ).map(([key, label]) => (
              <div key={key} className="tile count">
                <span className="tile-value">
                  {vaultCounts(vault.data.configured ? vault.data.categories : [])[key] ?? 0}
                </span>
                <span className="tile-label">{label}</span>
              </div>
            ))}
          </div>
        </>
      )}
    </section>
  )
}

// The pipelines: how many there are, how the runs of the week went, and the
// latest ones.
function PipelinesSummary({
  runs,
  count,
  now,
  onOpen,
}: {
  runs: LoadState<ExecutionSummary[]>
  count: LoadState<number>
  now: Date
  onOpen: (page: Page) => void
}) {
  return (
    <section className="card" aria-label="Pipelines">
      <h2 className="card-title">Pipelines</h2>
      {count.status === 'ready' && (
        <p className="muted small">
          {count.data} {count.data === 1 ? 'pipeline' : 'pipelines'} defined · runs of the last 7
          days
        </p>
      )}
      {runs.status === 'loading' && <p className="muted">Looking…</p>}
      {runs.status === 'failed' && <p className="muted">The runs could not be read.</p>}
      {runs.status === 'ready' && (
        <>
          <div className="tiles" aria-label="The last 7 days">
            {(() => {
              const c = runCounts(runs.data, now)
              return (
                [
                  ['completed', c.completed, 'good'],
                  ['failed', c.failed, 'bad'],
                  ['interrupted', c.interrupted, 'bad'],
                  ['running', c.running, 'plain'],
                ] as const
              ).map(([label, value, tone]) => (
                <div key={label} className="tile" data-tone={value > 0 ? tone : 'plain'}>
                  <span className="tile-value">{value}</span>
                  <span className="tile-label">{label}</span>
                </div>
              ))
            })()}
          </div>
          {recentRuns(runs.data, 5).length > 0 && (
            <ul className="attention-list">
              {recentRuns(runs.data, 5).map((run) => (
                <li key={run.id}>
                  <button
                    className="attention-item attention-link run-row"
                    onClick={() => onOpen({ kind: 'execution', id: run.id })}
                  >
                    <span className="attention-label">{run.pipeline ?? 'unknown pipeline'}</span>
                    <StatusBadge status={run.status} />
                  </button>
                </li>
              ))}
            </ul>
          )}
          {runs.data.length === 0 && <p className="muted small">No runs yet.</p>}
        </>
      )}
    </section>
  )
}

// The graphs this machine has local files for: choosing one opens the search of it.
function GraphSummary({ onOpen }: { onOpen: (page: Page) => void }) {
  const loadGraphs = useCallback(() => listGraphs(transport), [])
  const graphs = useLoad(loadGraphs, REFRESH_MS)
  return (
    <section className="card" aria-label="Code graph">
      <h2 className="card-title">Code graph</h2>
      {graphs.state.status === 'loading' && <p className="muted">Looking…</p>}
      {graphs.state.status === 'failed' && <p className="muted">The graphs could not be read.</p>}
      {graphs.state.status === 'ready' && graphs.state.data.length === 0 && (
        <p className="muted small">
          No graph has local files yet. Build one in a repository with the{' '}
          <code>/synapse-init</code> skill.
        </p>
      )}
      {graphs.state.status === 'ready' && graphs.state.data.length > 0 && (
        <>
          <p className="muted small">
            Search the symbols, files and nodes of {graphs.state.data.length}{' '}
            {graphs.state.data.length === 1 ? 'graph' : 'graphs'}
          </p>
          <div className="chips">
            {graphs.state.data.map((graph) => (
              <button
                key={graph.namespace}
                className="chip-plain chip-button"
                onClick={() => {
                  remember(graph.namespace)
                  onOpen({ kind: 'graph' })
                }}
              >
                {graph.namespace}
              </button>
            ))}
          </div>
        </>
      )}
    </section>
  )
}

// What is going now: pipeline runs, and the terminals that are open.
function RunningNow({
  runs,
  terminals,
  onOpen,
  onSelectTerminal,
}: {
  runs: LoadState<ExecutionSummary[]>
  terminals: readonly TerminalSession[]
  onOpen: (page: Page) => void
  onSelectTerminal: (id: string) => void
}) {
  const running = runs.status === 'ready' ? runs.data.filter((r) => r.status === 'running') : []
  if (running.length === 0 && terminals.length === 0) return null
  return (
    <section className="card" aria-label="Running now">
      <h2 className="card-title">Running now</h2>
      <ul className="attention-list">
        {running.map((run) => (
          <li key={run.id}>
            <button
              className="attention-item attention-link run-row"
              onClick={() => onOpen({ kind: 'execution', id: run.id })}
            >
              <span className="attention-label">
                {run.pipeline ?? 'A pipeline'}
                {run.currentStep !== null && (
                  <span className="muted small"> · step {run.currentStep}</span>
                )}
              </span>
              <StatusBadge status="running" />
            </button>
          </li>
        ))}
        {terminals.map((session) => (
          <li key={session.id}>
            <button
              className="attention-item attention-link"
              onClick={() => onSelectTerminal(session.id)}
            >
              <span className="attention-label">
                {session.title}
                <span className="muted small"> · terminal</span>
              </span>
            </button>
          </li>
        ))}
      </ul>
    </section>
  )
}

function QuickActions({
  onOpen,
  onStartTerminal,
}: {
  onOpen: (page: Page) => void
  onStartTerminal: (kind: TerminalKind) => void
}) {
  return (
    <div className="quick-actions" role="group" aria-label="Quick actions">
      <button className="secondary" onClick={() => onStartTerminal('Shell')}>
        New shell
      </button>
      <button className="secondary" onClick={() => onStartTerminal('Claude')}>
        Claude Code
      </button>
      <button className="secondary" onClick={() => onStartTerminal('Codex')}>
        Codex
      </button>
      <button className="secondary" onClick={() => onStartTerminal('Opencode')}>
        OpenCode
      </button>
      <button
        className="secondary"
        onClick={() => onOpen({ kind: 'create', definition: 'pipeline' })}
      >
        New pipeline
      </button>
    </div>
  )
}

// Where things stand: what needs attention, what is going, and a card for each
// part of Synapse.
export function HomePage({
  onOpen,
  terminals,
  onSelectTerminal,
  onStartTerminal,
}: {
  onOpen: (page: Page) => void
  terminals: readonly TerminalSession[]
  onSelectTerminal: (id: string) => void
  onStartTerminal: (kind: TerminalKind) => void
}) {
  const { state: config } = useConfig()
  const loadVault = useCallback(() => loadVaultAttention(transport), [])
  const loadRuns = useCallback(() => listExecutions(transport), [])
  const loadHarnesses = useCallback(async () => (await transport.getIntegrations()).harnesses, [])
  const loadCount = useCallback(
    async () => (await listDefinitions(transport)).filter((d) => d.kind === 'pipeline').length,
    [],
  )
  const vault = useLoad(loadVault, REFRESH_MS)
  const runs = useLoad(loadRuns, REFRESH_MS)
  const harnesses = useLoad(loadHarnesses, REFRESH_MS)
  const count = useLoad(loadCount, REFRESH_MS)
  // The graphs that have a repository saved are checked against it, which reads
  // every file they cover, so it is done less often than the rest.
  const repos = config.status === 'ready' ? config.config.graphRepos : null
  const loadGraphLines = useCallback(async (): Promise<GraphLine[]> => {
    const lines: GraphLine[] = []
    for (const namespace of Object.keys(repos ?? {})) {
      try {
        const line = healthLine(namespace, await transport.graphHealth(namespace))
        if (line !== null) lines.push({ namespace, line })
      } catch {
        // A graph that cannot be read is not a line; its own page says why.
      }
    }
    return lines
  }, [repos])
  const graphLines = useLoad(loadGraphLines, 120_000)

  const now = new Date()
  const inputs: AttentionInputs = {
    config:
      config.status === 'ready'
        ? { status: 'ready', data: config.config }
        : config.status === 'loading'
          ? { status: 'loading' }
          : { status: 'failed', error: config.error },
    vault: asSource(vault.state),
    runs: asSource(runs.state),
    integrations: asSource(harnesses.state),
    graphs: repos === null ? { status: 'loading' } : asSource(graphLines.state),
    now,
  }

  function refresh() {
    vault.reload()
    runs.reload()
    harnesses.reload()
    count.reload()
    graphLines.reload()
  }

  return (
    <div className="page home">
      <header className="home-head">
        <h1 className="page-title">Home</h1>
        <QuickActions onOpen={onOpen} onStartTerminal={onStartTerminal} />
      </header>
      <RunningNow
        runs={runs.state}
        terminals={terminals}
        onOpen={onOpen}
        onSelectTerminal={onSelectTerminal}
      />
      <div className="home-grid">
        <div className="home-column">
          <NeedsAttention inputs={inputs} onRefresh={refresh} onOpen={onOpen} />
          <Continue onOpen={onOpen} />
          <PipelinesSummary runs={runs.state} count={count.state} now={now} onOpen={onOpen} />
        </div>
        <div className="home-column">
          <SetupCard inputs={inputs} onOpen={onOpen} />
          <VaultSummary vault={vault.state} onOpen={onOpen} />
          <GraphSummary onOpen={onOpen} />
        </div>
      </div>
    </div>
  )
}
