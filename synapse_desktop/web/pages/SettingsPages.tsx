import { useCallback, useEffect, useState, type ReactNode } from 'react'
import type { Harness } from '../../shared/transport.ts'
import {
  loadSettings,
  settingsOf,
  type SynapseSetting,
  type SynapseSettings,
} from '../domain/settings.ts'
import {
  HARNESS_NAMES,
  installOffer,
  stateLabel,
  writesFor,
  type InstallOffer,
} from '../domain/integrations.ts'
import { isAbsolutePath } from '../domain/vaults.ts'
import { transport } from '../transport/index.ts'
import { TEXT_SIZES } from '../domain/text-size.ts'
import { useConfig } from '../state/config.tsx'
import { useDiagnosis, useHarnesses } from '../state/diagnosis.tsx'
import { EnvCard } from '../components/EnvCard.tsx'
import { ModelPicker } from '../components/ModelPicker.tsx'
import { Conventions } from './ConventionsPage.tsx'
import { SettingsForm } from '../components/SettingsForm.tsx'
import type { SettingsSection } from '../state/state.ts'
import { currentTextSize, setTextSize } from '../state/text-size.ts'
import { useLoad } from '../state/useLoad.ts'
import { VaultCard } from '../components/VaultCard.tsx'

// A card with one path in it, saved with its button; empty is none.
function PathCard({
  title,
  hint,
  label,
  placeholder,
  initial,
  onSave,
}: {
  title: string
  hint: string
  label: string
  placeholder: string
  initial: string
  onSave: (path: string | null) => Promise<void>
}) {
  const [draft, setDraft] = useState(initial)
  const [message, setMessage] = useState<string | null>(null)

  async function submit(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    try {
      const trimmed = draft.trim()
      await onSave(trimmed === '' ? null : trimmed)
      setMessage('Saved.')
    } catch (error) {
      setMessage(`Not saved: ${String(error)}`)
    }
  }

  return (
    <form className="card" aria-label={title} onSubmit={(event) => void submit(event)}>
      <h2 className="card-title">{title}</h2>
      <p className="muted">{hint}</p>
      <input
        aria-label={label}
        className="mono"
        value={draft}
        placeholder={placeholder}
        onChange={(event) => {
          setDraft(event.target.value)
          setMessage(null)
        }}
      />
      <div className="row">
        <button type="submit" className="primary">
          Save
        </button>
        {message !== null && <span role="status">{message}</span>}
      </div>
    </form>
  )
}

const HARNESS_OPTIONS: readonly { value: Harness; label: string }[] = [
  { value: 'Claude', label: 'Claude Code' },
  { value: 'Codex', label: 'Codex' },
  { value: 'Opencode', label: 'OpenCode' },
]

// The harness that writes a definition for you, until another is chosen on the
// page that asks.
function DefaultHarnessCard() {
  const { state, save } = useConfig()
  const harnesses = useHarnesses()
  const [failure, setFailure] = useState<string | null>(null)
  if (state.status !== 'ready') return null
  const chosen = state.config.defaultHarness
  const used = HARNESS_OPTIONS.find((h) => h.value === harnesses.defaultHarness)?.label
  return (
    <section className="card" aria-label="Default harness">
      <h2 className="card-title">Default harness</h2>
      <p className="muted">
        The harness that writes a definition or a note when you ask an agent to, and that a step
        uses when it names none. Without one, the first that is installed is used.
      </p>
      {chosen !== null && harnesses.isMissing(chosen) && (
        <p className="warn-line" role="status">
          {harnesses.reason(chosen)}, so {used} is used instead.
        </p>
      )}
      <select
        aria-label="Default harness"
        value={state.config.defaultHarness ?? ''}
        onChange={(event) => {
          const value = event.target.value
          save({ defaultHarness: value === '' ? null : (value as Harness) }).then(
            () => setFailure(null),
            (error: unknown) => setFailure(String(error)),
          )
        }}
      >
        <option value="">Not chosen ({used})</option>
        {HARNESS_OPTIONS.map((h) => (
          <option key={h.value} value={h.value} disabled={harnesses.isMissing(h.value)}>
            {h.label}
            {harnesses.isMissing(h.value) ? ' (not installed)' : ''}
          </option>
        ))}
      </select>
      {failure !== null && (
        <p className="error" role="alert">
          {failure}
        </p>
      )}
    </section>
  )
}

// The model each harness is asked to use when nothing says another, found among the models it
// lists or typed. Without one the harness uses its own.
function DefaultModelsCard() {
  const { state, save } = useConfig()
  const harnesses = useHarnesses()
  const [failure, setFailure] = useState<string | null>(null)
  if (state.status !== 'ready') return null
  const models = state.config.defaultModels

  function change(harness: Harness, model: string | null) {
    const next = { ...models }
    if (model === null) delete next[harness]
    else next[harness] = model
    save({ defaultModels: next }).then(
      () => setFailure(null),
      (error: unknown) => setFailure(String(error)),
    )
  }

  return (
    <section className="card" aria-label="Default models">
      <h2 className="card-title">Default models</h2>
      <p className="muted">
        The model a harness is asked to use when an agent writes a definition or a note for you.
        Without one, the harness uses its own. A step of a pipeline names its own in the definition.
      </p>
      {HARNESS_OPTIONS.map(({ value, label }) => (
        <div key={value} className="model-row">
          <span className="model-row-label">{label}</span>
          <ModelPicker
            harness={value}
            label={`Default model of ${label}`}
            value={models[value] ?? null}
            onChange={(model) => change(value, model)}
            disabled={harnesses.isMissing(value)}
          />
        </div>
      ))}
      {failure !== null && (
        <p className="error" role="alert">
          {failure}
        </p>
      )}
    </section>
  )
}

// The folders of definitions besides the default one.
function DefinitionFoldersCard({ onChanged }: { onChanged: () => void }) {
  const { state, save } = useConfig()
  const [draft, setDraft] = useState('')
  const [failure, setFailure] = useState<string | null>(null)
  if (state.status !== 'ready') return null
  const folders = state.config.definitionPaths

  async function change(next: string[]) {
    try {
      await save({ definitionPaths: next })
      setFailure(null)
      onChanged()
    } catch (error) {
      setFailure(String(error))
    }
  }

  async function add(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    const path = draft.trim()
    if (!isAbsolutePath(path)) {
      setFailure('The path must be absolute.')
      return
    }
    if (!folders.includes(path)) await change([...folders, path])
    setDraft('')
  }

  return (
    <section className="card" aria-label="Definition folders">
      <h2 className="card-title">Definition folders</h2>
      <p className="muted">
        Folders of definitions besides the default one, which is{' '}
        <span className="mono">synapse-pipeline</span> in your configuration folder. They are looked
        in after the folders of <span className="mono">SYNAPSE_PIPELINE_PATH</span>.
      </p>
      {folders.length === 0 && <p className="muted">None are added.</p>}
      <ul className="env-list">
        {folders.map((folder) => (
          <li key={folder} className="env-row">
            <span className="mono env-value">{folder}</span>
            <span />
            <button
              className="link"
              onClick={() => void change(folders.filter((f) => f !== folder))}
            >
              Remove
            </button>
          </li>
        ))}
      </ul>
      <form className="row" onSubmit={(event) => void add(event)}>
        <input
          className="mono"
          aria-label="Folder to add"
          placeholder="/path/to/definitions"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
        <button type="submit" className="secondary" disabled={draft.trim() === ''}>
          Add
        </button>
      </form>
      {failure !== null && (
        <p className="error" role="alert">
          {failure}
        </p>
      )}
    </section>
  )
}

// How big the text of the app is, which is kept in this browser and takes effect at once.
function TextSizeCard() {
  const [percent, setPercent] = useState(currentTextSize())
  return (
    <section className="card" aria-label="Text size">
      <h2 className="card-title">Text size</h2>
      <p className="muted">
        How big the text is, in the whole app. Wide screens show it smaller than it is, so the
        default is a little over the browser&apos;s own size. This is kept in this browser.
      </p>
      <select
        aria-label="Text size"
        value={percent}
        onChange={(event) => {
          const next = Number(event.target.value)
          setTextSize(next)
          setPercent(next)
        }}
      >
        {TEXT_SIZES.map((size) => (
          <option key={size.percent} value={size.percent}>
            {size.label} ({size.percent}%)
          </option>
        ))}
      </select>
    </section>
  )
}

function General({ onChanged }: { onChanged: () => void }) {
  const { state, save } = useConfig()
  return (
    <>
      {state.status === 'loading' && <p className="muted">Loading…</p>}
      {state.status === 'failed' && <p role="alert">The server did not answer: {state.error}</p>}
      {state.status === 'ready' && (
        <PathCard
          title="Work directory"
          hint="Where Synapse keeps its working files: the code graph has a folder in it for each repository and branch, and runs are recorded in pipelines/ under it. Without a choice here it is ~/.cache/synapse/work. The SYNAPSE_WORK_DIR variable, when the app was started with it or you set it under Environment, is used instead of what is saved here."
          label="Work directory path"
          placeholder="~/.cache/synapse/work"
          initial={state.config.workDir ?? ''}
          onSave={(path) => save({ workDir: path }).then(() => onChanged())}
        />
      )}
      <TextSizeCard />
      <DefaultHarnessCard />
      <DefaultModelsCard />
      <DefinitionFoldersCard onChanged={onChanged} />
    </>
  )
}

// The settings of Synapse, read again after any change: a vault, a variable or a
// setting each show up in the others.
function WithSynapseSettings({
  children,
}: {
  children: (settings: SynapseSettings, changed: () => void) => ReactNode
}) {
  const [version, setVersion] = useState(0)
  const load = useCallback(() => loadSettings(transport), [])
  const { state } = useLoad(load, undefined, version)
  if (state.status === 'loading') return <p className="muted">Loading the settings…</p>
  if (state.status === 'failed') {
    return <p role="alert">Could not read the settings of Synapse: {state.error}</p>
  }
  return <>{children(state.data, () => setVersion((v) => v + 1))}</>
}

function Vault() {
  return (
    <WithSynapseSettings>
      {(loaded, changed) => (
        <>
          <VaultCard
            vault={loaded.settings.find((s) => s.key === 'SYNAPSE_VAULT_DIR')}
            onChanged={changed}
          />
          <SettingsForm
            title="Keeping the vault"
            settings={settingsOf(loaded.settings, 'vault')}
            write={loaded.write}
            onChanged={changed}
          />
        </>
      )}
    </WithSynapseSettings>
  )
}

// The projects notes belong to, which a person adds here by hand and the New note page
// and the note skills read.
function Graph() {
  return (
    <WithSynapseSettings>
      {(loaded, changed) => (
        <SettingsForm
          title="Code graph"
          settings={settingsOf(loaded.settings, 'graph')}
          write={loaded.write}
          onChanged={changed}
        />
      )}
    </WithSynapseSettings>
  )
}

// The variables Synapse reads, with what each is when nothing sets it and what is
// in force now. "Use" begins the form above with the variable and its default.
function Known({
  settings,
  onUse,
}: {
  settings: SynapseSetting[]
  onUse: (setting: SynapseSetting) => void
}) {
  const known = settings.filter((s) => s.environment)
  return (
    <section className="card" aria-label="Variables Synapse reads">
      <h2 className="card-title">Variables Synapse reads</h2>
      <p className="muted small">
        Each can be set here or in synapse.conf. The default is what applies when neither sets it.
      </p>
      <ul className="env-list">
        {known.map((s) => (
          <li key={s.key} className="known-row">
            <span className="mono env-name">{s.key}</span>
            <span className="muted small">{s.description}</span>
            <span className="small">
              Default <span className="mono">{s.default ?? '(none)'}</span>
              {' · '}
              {s.source === 'environment'
                ? 'now from the environment: '
                : s.source === 'file'
                  ? 'now from synapse.conf: '
                  : 'now: '}
              <span className="mono">{s.value ?? '(unset)'}</span>
            </span>
            <button className="link" onClick={() => onUse(s)}>
              Use
            </button>
          </li>
        ))}
      </ul>
    </section>
  )
}

function Environment() {
  const [start, setStart] = useState<{ name: string; value: string; n: number } | null>(null)
  return (
    <WithSynapseSettings>
      {(loaded, changed) => (
        <>
          <EnvCard key={start?.n ?? 0} start={start ?? undefined} onChanged={changed} />
          <Known
            settings={loaded.settings}
            onUse={(s) => setStart({ name: s.key, value: s.default ?? '', n: (start?.n ?? 0) + 1 })}
          />
        </>
      )}
    </WithSynapseSettings>
  )
}

// What each harness has of Synapse, and a button that installs it from the copy
// of Synapse this app has. Nothing is written into a harness until one is
// pressed.
function IntegrationsPage({
  onRunCommand,
}: {
  onRunCommand: (command: string, title: string) => void
}) {
  const harnessesNow = useHarnesses()
  const { recheck } = useDiagnosis()
  // The harness whose installing is being asked about.
  const [asking, setAsking] = useState<Harness | null>(null)
  const load = useCallback(() => transport.getIntegrations(), [])
  const { state } = useLoad(load)
  // What the page says is read again when it is opened, such as on coming back from the
  // terminal tab that installed; the setup check is told as well.
  useEffect(() => recheck(), [recheck])

  function run(harness: Harness, offer: InstallOffer) {
    setAsking(null)
    onRunCommand(offer.command, `${offer.label} ${HARNESS_NAMES[harness]}`)
  }

  if (state.status === 'loading') return <p className="muted">Looking at the harnesses…</p>
  if (state.status === 'failed') return <p role="alert">Could not look: {state.error}</p>
  const { bundled, harnesses } = state.data
  const ready = bundled.contentRoot !== null && bundled.pipelineRoot !== null
  return (
    <>
      <section className="card" aria-label="This app's Synapse">
        <h2 className="card-title">The Synapse this app has</h2>
        {bundled.hook === null ? (
          <p role="alert">
            No <span className="mono">synapse</span> program was found on PATH, so there is nothing
            to install.
          </p>
        ) : (
          <p className="muted">
            Version <span className="mono">{bundled.version ?? 'unknown'}</span>, hook program{' '}
            <span className="mono">{bundled.hook}</span>
          </p>
        )}
        {!ready && bundled.hook !== null && (
          <p role="alert">Its skills, commands and hook templates were not found.</p>
        )}
      </section>
      {harnesses.map((item) => {
        const offer = installOffer(item.harness, item.state)
        const missing = harnessesNow.isMissing(item.harness)
        return (
          <section key={item.harness} className="card" aria-label={HARNESS_NAMES[item.harness]}>
            <h2 className="card-title">{HARNESS_NAMES[item.harness]}</h2>
            <p>
              <span data-state={item.state}>{stateLabel(item.state)}</span>
              {item.version !== null && (
                <span className="muted">
                  {' '}
                  · version <span className="mono">{item.version}</span>
                </span>
              )}
            </p>
            {missing && (
              <p className="warn-line" role="status">
                {harnessesNow.reason(item.harness)}, so there is nothing to install Synapse in.
              </p>
            )}
            {item.hook !== null && (
              <p className="muted small">
                Hook program <span className="mono">{item.hook}</span>
              </p>
            )}
            {offer !== null && (
              <div className="row">
                <button
                  className="primary"
                  disabled={missing}
                  onClick={() => setAsking(item.harness)}
                >
                  {offer.label}
                </button>
              </div>
            )}
            {offer !== null && asking === item.harness && (
              <div className="confirm" role="alertdialog" aria-label="Are you sure?">
                <p>
                  <strong>Are you sure?</strong> This opens a terminal tab and runs this in it:
                </p>
                <pre className="mono small">{offer.command}</pre>
                <p>
                  It installs the npm packages for every program on this machine, and writes into{' '}
                  {HARNESS_NAMES[item.harness]}'s own configuration:
                </p>
                <ul className="small">
                  {writesFor(item.harness).map((line) => (
                    <li key={line}>{line}</li>
                  ))}
                </ul>
                <div className="row">
                  <button className="primary" onClick={() => run(item.harness, offer)}>
                    Yes, {offer.label.toLowerCase()}
                  </button>
                  <button className="secondary" onClick={() => setAsking(null)}>
                    Cancel
                  </button>
                </div>
              </div>
            )}
          </section>
        )
      })}
      <p className="muted small">
        Installing and updating run npm in a terminal tab, which you can watch and stop. Synapse is
        installed from its npm package, so the hook path that a harness keeps stays where it is when
        this app moves or updates, and the app writes no hook path of its own. Where Synapse is
        current or newer than this app&apos;s, nothing is offered. A harness started from the
        Terminals page loads Synapse for that session without any of this.
      </p>
    </>
  )
}

function Terminals() {
  const { state, save } = useConfig()
  if (state.status === 'loading') return <p className="muted">Loading the settings…</p>
  if (state.status === 'failed') {
    return <p role="alert">The server did not answer: {state.error}</p>
  }
  return (
    <>
      <PathCard
        title="Start folder"
        hint="Where a new shell starts, unless you type another folder on the Terminals page. Empty is your home folder."
        label="Start folder path"
        placeholder="your home folder"
        initial={state.config.terminalFolder ?? ''}
        onSave={(path) => save({ terminalFolder: path })}
      />
      <section className="card" aria-label="About terminals">
        <h2 className="card-title">About terminals</h2>
        <p className="muted">
          A shell tab runs your login shell, so your own start-up files are read. In it,{' '}
          <span className="mono">claude</span>, <span className="mono">codex</span> and{' '}
          <span className="mono">opencode</span> load the Synapse that comes with the app for that
          run only, unless Synapse is installed in the harness, and the conversation of a Claude
          Code or Codex session shows under the terminal.
        </p>
      </section>
    </>
  )
}

const TITLES: Record<SettingsSection, string> = {
  general: 'General',
  vault: 'Vault',
  conventions: 'Conventions',
  graph: 'Code graph',
  environment: 'Environment',
  integrations: 'Integrations',
  terminals: 'Terminals',
}

// One category of the settings.
export function SettingsPage({
  section,
  onChanged,
  onRunCommand,
}: {
  section: SettingsSection
  // Something the lists of definitions or runs show has changed.
  onChanged: () => void
  // A shell tab is opened and runs the command.
  onRunCommand: (command: string, title: string) => void
}) {
  return (
    <div className="page">
      <h1 className="page-title">{TITLES[section]}</h1>
      {section === 'general' && <General onChanged={onChanged} />}
      {section === 'vault' && <Vault />}
      {section === 'conventions' && <Conventions />}
      {section === 'graph' && <Graph />}
      {section === 'environment' && <Environment />}
      {section === 'integrations' && <IntegrationsPage onRunCommand={onRunCommand} />}
      {section === 'terminals' && <Terminals />}
    </div>
  )
}
