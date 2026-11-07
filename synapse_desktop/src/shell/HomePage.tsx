import { useCallback } from 'react'
import {
  attentionFailures,
  attentionGroups,
  isSettled,
  loadVaultAttention,
  type AttentionItem,
  type AttentionTarget,
  type Source,
} from '../domain/attention.ts'
import { listExecutions } from '../domain/executions.ts'
import { transport } from '../transport/index.ts'
import { useConfig } from './config.tsx'
import { RefreshIcon } from './icons.tsx'
import type { Page } from './state.ts'
import { useLoad, type LoadState } from './useLoad.ts'

const REFRESH_MS = 30_000

function asSource<T>(state: LoadState<T>): Source<T> {
  return state
}

function pageOf(target: AttentionTarget): Page {
  return target.kind === 'settings'
    ? { kind: 'settings', section: target.section }
    : { kind: 'execution', id: target.id }
}

function ItemRow({ item, onOpen }: { item: AttentionItem; onOpen: (page: Page) => void }) {
  const body = (
    <>
      <span className="attention-label">{item.label}</span>
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

// The things worth looking at: what is missing, runs that went wrong and what
// the vault wants decided. Each source is read on its own, so one that fails is
// said so and the rest still show.
function NeedsAttention({ onOpen }: { onOpen: (page: Page) => void }) {
  const { state: config } = useConfig()
  const loadVault = useCallback(() => loadVaultAttention(transport), [])
  const loadRuns = useCallback(() => listExecutions(transport), [])
  const loadHarnesses = useCallback(async () => (await transport.getIntegrations()).harnesses, [])
  const vault = useLoad(loadVault, REFRESH_MS)
  const runs = useLoad(loadRuns, REFRESH_MS)
  const harnesses = useLoad(loadHarnesses, REFRESH_MS)

  const inputs = {
    config:
      config.status === 'ready'
        ? ({ status: 'ready', data: config.config } as const)
        : asSource<never>(config.status === 'loading' ? { status: 'loading' } : config),
    vault: asSource(vault.state),
    runs: asSource(runs.state),
    integrations: asSource(harnesses.state),
    now: new Date(),
  }
  const groups = attentionGroups(inputs)
  const failures = attentionFailures(inputs)
  const settled = isSettled(inputs)

  function refresh() {
    vault.reload()
    runs.reload()
    harnesses.reload()
  }

  return (
    <section className="card" aria-label="Needs attention">
      <div className="card-head">
        <h2 className="card-title">Needs attention</h2>
        <button className="icon-button" aria-label="Refresh" onClick={refresh}>
          <RefreshIcon />
        </button>
      </div>
      {!settled && groups.length === 0 && <p className="muted">Looking…</p>}
      {settled && groups.length === 0 && failures.length === 0 && (
        <p className="muted">Nothing needs attention.</p>
      )}
      {groups.map((group) => (
        <div key={group.key} className="attention-group">
          <h3 className="attention-title">{group.title}</h3>
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

// Where things stand: the cards of what the app knows.
export function HomePage({ onOpen }: { onOpen: (page: Page) => void }) {
  return (
    <div className="page">
      <h1 className="page-title">Home</h1>
      <NeedsAttention onOpen={onOpen} />
    </div>
  )
}
