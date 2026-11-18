import { useCallback } from 'react'
import { loadVaultAttention, vaultGroups } from '../domain/attention.ts'
import { noteCount, vaultSections } from '../domain/vault-sections.ts'
import { describeVault } from '../domain/vaults.ts'
import { transport } from '../transport/index.ts'
import { ItemRow } from '../components/AttentionRows.tsx'
import { RefreshIcon } from '../components/icons.tsx'
import type { Page } from '../state/state.ts'
import { useLoad } from '../state/useLoad.ts'
import { useWatch } from '../state/useWatch.ts'

// The vault changes under the app, written by agents in other windows.
// What no file shows is looked for now and then.
const REFRESH_MS = 60_000

// What `/synapse-status` says of the vault: the design notes still being discussed, the ones
// ready and not yet compiled, the open questions, the tasks in progress and those awaiting
// review. Every note is listed, and a click opens it.
export function VaultPage({ onOpen }: { onOpen: (page: Page) => void }) {
  const loadStatus = useCallback(() => loadVaultAttention(transport), [])
  const { state: status, reload } = useLoad(loadStatus, REFRESH_MS)
  useWatch('vault', reload)
  const path = status.status === 'ready' && status.data.configured ? status.data.vault : null
  const loadInfo = useCallback(
    () => (path === null ? Promise.resolve(null) : transport.inspectVault(path)),
    [path],
  )
  const { state: info } = useLoad(loadInfo)
  const groups = status.status === 'ready' ? vaultGroups(status.data) : []
  const sections = vaultSections(groups)

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <p className="eyebrow">Vault</p>
          <h1 className="page-title">What needs a decision</h1>
        </div>
        <div className="head-actions">
          <button className="icon-button" aria-label="Read the status again" onClick={reload}>
            <RefreshIcon />
          </button>
          <button
            className="secondary"
            onClick={() => onOpen({ kind: 'new-note' })}
            disabled={path === null}
          >
            New note
          </button>
        </div>
      </div>
      {status.status === 'loading' && <p className="muted">Reading the vault…</p>}
      {status.status === 'failed' && (
        <p role="alert">Could not read the vault status: {status.error}</p>
      )}
      {status.status === 'ready' && !status.data.configured && (
        <p className="muted">
          No vault is chosen.{' '}
          <button className="link" onClick={() => onOpen({ kind: 'settings', section: 'vault' })}>
            Choose one
          </button>
        </p>
      )}
      {path !== null && (
        <>
          <p className="mono small">{path}</p>
          {info.status === 'ready' && info.data !== null && (
            <p className="muted small">{describeVault(info.data)}</p>
          )}
        </>
      )}
      {status.status === 'ready' && status.data.configured && groups.length === 0 && (
        <p className="muted">Vault is clear — nothing outstanding.</p>
      )}
      {sections.map((section) => (
        <section key={section.key} className="vault-section" aria-label={section.title}>
          <header className="vault-section-head">
            <h2 className="vault-section-title">
              {section.title}
              <span className="count-pill">{noteCount(section)}</span>
            </h2>
            {section.about !== '' && <p className="muted small">{section.about}</p>}
          </header>
          {section.groups.map((group) => (
            <section key={group.key} className="card" aria-label={group.title}>
              <h3 className="card-title">
                {group.title}
                <span className="count-pill">{group.items.length}</span>
              </h3>
              {group.about !== null && <p className="muted small">{group.about}</p>}
              <ul className="attention-list">
                {group.items.map((item) => (
                  <ItemRow key={item.key} item={item} onOpen={onOpen} />
                ))}
              </ul>
            </section>
          ))}
        </section>
      ))}
    </div>
  )
}
