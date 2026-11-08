import { useEffect, useState } from 'react'
import type { VaultInfo } from '../../shared/transport.ts'
import { saveSetting, type SynapseSetting } from '../domain/settings.ts'
import { describeVault, isAbsolutePath, rememberVault } from '../domain/vaults.ts'
import { transport } from '../transport/index.ts'
import { useConfig } from './config.tsx'
import { useDiagnosis } from './diagnosis.tsx'

const LOOK_MS = 400

// What a folder is as a vault, a moment after the path stops changing.
function useVaultInfo(path: string): { info: VaultInfo | null; failure: string | null } {
  const [answer, setAnswer] = useState<{ path: string; info: VaultInfo } | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  useEffect(() => {
    if (!isAbsolutePath(path)) return
    const timer = setTimeout(() => {
      transport
        .inspectVault(path)
        .then((info) => {
          setAnswer({ path, info })
          setFailure(null)
        })
        .catch((error: unknown) => setFailure(String(error)))
    }, LOOK_MS)
    return () => clearTimeout(timer)
  }, [path])
  return { info: answer !== null && answer.path === path ? answer.info : null, failure }
}

// The vault Synapse reads and writes: which it is, and a way to switch to
// another folder. The vault is the setting SYNAPSE_VAULT_DIR, so switching it is
// writing that setting.
export function VaultCard({
  vault,
  onChanged,
}: {
  vault: SynapseSetting | undefined
  onChanged: () => void
}) {
  const { state, save } = useConfig()
  const { recheck } = useDiagnosis()
  const recent = state.status === 'ready' ? state.config.recentVaults : []
  const current = vault?.value ?? null
  const [path, setPath] = useState('')
  const [switching, setSwitching] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  const wanted = path.trim()
  const looked = useVaultInfo(wanted)
  // Where the folder is once a leading ~ is the home folder.
  const resolved = looked.info?.path ?? wanted

  // `seed`: the folder is made a vault first, with an Index.md, when it is not one.
  async function use(seed: boolean) {
    setSwitching(true)
    setFailure(null)
    try {
      if (seed) await transport.seedVault(resolved)
      await saveSetting(transport, 'SYNAPSE_VAULT_DIR', resolved)
      await save({ recentVaults: rememberVault(recent, resolved) })
      setPath('')
      onChanged()
      // The vault was one of the things the setup check looks at.
      recheck()
    } catch (error) {
      setFailure(String(error).replace(/^Error: (synapse-config: )?/, ''))
    } finally {
      setSwitching(false)
    }
  }

  return (
    <section className="card" aria-label="Vault">
      <h2 className="card-title">Vault</h2>
      <p>
        {current === null ? (
          <span className="muted">No vault is set.</span>
        ) : (
          <span className="mono">{current}</span>
        )}
      </p>
      {vault?.source === 'environment' && (
        <p className="warn-line" role="status">
          The vault comes from the environment
          {vault.shadowed ? ` and not from the file, which says ${vault.file_value ?? ''}` : ''}.
          Switching writes the file, and the environment still wins until it is changed or
          overridden below.
        </p>
      )}
      <label className="field">
        <span className="muted small">
          Switch to another folder. Every Synapse command reads the new vault, in this app and in a
          terminal.
        </span>
        <input
          className="mono"
          value={path}
          placeholder="/path/to/a/vault"
          onChange={(event) => setPath(event.target.value)}
        />
      </label>
      {wanted !== '' && !isAbsolutePath(wanted) && (
        <p className="muted small">The path must be absolute.</p>
      )}
      {looked.info !== null && <p className="muted small">{describeVault(looked.info)}</p>}
      {looked.failure !== null && <p className="error">{looked.failure}</p>}
      {recent.length > 0 && (
        <div className="chips" aria-label="Recent vaults">
          {recent.map((vaultPath) => (
            <button
              key={vaultPath}
              className="chip mono"
              aria-pressed={vaultPath === wanted}
              onClick={() => setPath(vaultPath)}
            >
              {vaultPath}
            </button>
          ))}
        </div>
      )}
      <div className="row">
        <button
          className="primary"
          disabled={
            switching || looked.info === null || !looked.info.exists || resolved === current
          }
          onClick={() => void use(false)}
        >
          {switching ? 'Switching…' : 'Use this vault'}
        </button>
        {looked.info !== null && (!looked.info.exists || !looked.info.hasIndex) && (
          <button
            className="secondary"
            disabled={switching || resolved === current}
            onClick={() => void use(true)}
          >
            {looked.info.exists ? 'Add an Index.md and use it' : 'Create this vault'}
          </button>
        )}
      </div>
      {failure !== null && (
        <p className="error" role="alert">
          {failure}
        </p>
      )}
    </section>
  )
}
