import { useCallback, useState } from 'react'
import {
  clearSetting,
  isWholeNumber,
  loadSettings,
  saveSetting,
  type SynapseSetting,
} from '../domain/settings.ts'
import { transport } from '../transport/index.ts'
import { useLoad } from './useLoad.ts'

// Where a setting's value in force comes from, in words.
function sourceText(setting: SynapseSetting): string {
  switch (setting.source) {
    case 'environment':
      return setting.shadowed
        ? `${setting.value ?? ''} from the environment, which wins over the file's ${setting.file_value ?? ''}`
        : `${setting.value ?? ''} from the environment`
    case 'file':
      return `${setting.value ?? ''} from the file`
    case 'default':
      return `${setting.value ?? ''}, the default`
    case 'unset':
      return setting.required ? 'not set, and nothing works until it is' : 'not set'
  }
}

// One setting: what the file says, as an input of the kind it has. A change is
// written when the input is left or Enter is pressed; the program says if the
// value does not fit.
function SettingRow({ setting, onChanged }: { setting: SynapseSetting; onChanged: () => void }) {
  const inFile = setting.file_value ?? ''
  const [draft, setDraft] = useState(inFile)
  const [failure, setFailure] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  async function commit(next: string) {
    if (next === inFile) {
      setFailure(null)
      return
    }
    if (setting.kind === 'number' && next !== '' && !isWholeNumber(next)) {
      setFailure(`${setting.key} takes a whole number of at most 9 digits`)
      return
    }
    setSaving(true)
    try {
      if (next === '') await clearSetting(transport, setting.key)
      else await saveSetting(transport, setting.key, next)
      setFailure(null)
      onChanged()
    } catch (error) {
      setFailure(String(error).replace(/^Error: (synapse-config: )?/, ''))
    } finally {
      setSaving(false)
    }
  }

  const id = `setting-${setting.key}`
  return (
    <div className="setting">
      <div className="setting-head">
        <label htmlFor={id} className="mono setting-key">
          {setting.key}
        </label>
        {setting.required && <span className="muted small">required</span>}
      </div>
      <p className="muted small">{setting.description}</p>
      {setting.kind === 'toggle' ? (
        <label className="row">
          <input
            id={id}
            type="checkbox"
            checked={inFile !== ''}
            disabled={saving}
            onChange={(event) => void commit(event.target.checked ? '1' : '')}
          />
          <span>On</span>
        </label>
      ) : (
        <input
          id={id}
          className="mono"
          value={draft}
          disabled={saving}
          inputMode={setting.kind === 'number' ? 'numeric' : undefined}
          placeholder={setting.default ?? 'not set'}
          onChange={(event) => setDraft(event.target.value)}
          onBlur={() => void commit(draft.trim())}
          onKeyDown={(event) => {
            if (event.key === 'Enter') event.currentTarget.blur()
            if (event.key === 'Escape') {
              // Back to what the file says, with the refusal gone.
              setDraft(inFile)
              setFailure(null)
            }
          }}
        />
      )}
      <p className="muted small" aria-live="polite">
        {sourceText(setting)}
        {inFile !== '' && (
          <>
            {' · '}
            <button
              className="link"
              disabled={saving}
              onClick={() => {
                setDraft('')
                void commit('')
              }}
            >
              Reset
            </button>
          </>
        )}
      </p>
      {failure !== null && (
        <p className="error" role="alert">
          {failure}
        </p>
      )}
    </div>
  )
}

// The settings of `synapse.conf`, one input to a setting.
export function SettingsForm() {
  const [version, setVersion] = useState(0)
  const load = useCallback(() => loadSettings(transport), [])
  const { state } = useLoad(load, undefined, version)

  if (state.status === 'loading') return <p className="muted">Loading the settings…</p>
  if (state.status === 'failed') {
    return <p role="alert">Could not read the settings: {state.error}</p>
  }
  const { settings, write } = state.data
  return (
    <section className="card" aria-label="Synapse settings">
      <h2 className="card-title">Synapse settings</h2>
      <p className="muted small">
        These are the settings of <span className="mono">synapse.conf</span>.{' '}
        {write === null
          ? 'There is no home directory to keep them in.'
          : `A change is written to ${write}, and no other line of it changes.`}
      </p>
      <div className="settings">
        {settings.map((setting) => (
          // The file's text is part of the key, so that a row starts again from what
          // the file says after it changes.
          <SettingRow
            key={`${setting.key}:${setting.file_value ?? ''}`}
            setting={setting}
            onChanged={() => setVersion((v) => v + 1)}
          />
        ))}
      </div>
    </section>
  )
}
