import { useState } from 'react'
import type { NoteKind } from '../../shared/transport.ts'
import { transport } from '../transport/index.ts'
import { useConfig } from './config.tsx'
import { TERMINAL_LABELS, type Page } from './state.ts'

const KINDS: { kind: NoteKind; label: string; about: string; placeholder: string }[] = [
  {
    kind: 'note',
    label: 'Note',
    about: 'Any note to keep: research, an idea, something learned.',
    placeholder: 'What should the note say?',
  },
  {
    kind: 'task',
    label: 'Task note',
    about: 'A tracked task, with a status and a checklist.',
    placeholder: 'What is the task, and what are its steps?',
  },
  {
    kind: 'design',
    label: 'Design note',
    about: 'A design discussion, written down as it stands.',
    placeholder: 'What is being designed, and what is decided so far?',
  },
]

// Describe a note and have an agent write it into the vault the way the vault's
// own commands do; the note opens when it is written.
export function NewNotePage({ onCreated }: { onCreated: (page: Page) => void }) {
  const { state: config } = useConfig()
  const harness = config.status === 'ready' ? (config.config.defaultHarness ?? 'Claude') : 'Claude'
  const [kind, setKind] = useState<NoteKind>('note')
  const [prompt, setPrompt] = useState('')
  const [working, setWorking] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  const current = KINDS.find((k) => k.kind === kind) ?? KINDS[0]

  async function write() {
    setWorking(true)
    setFailure(null)
    try {
      const { path } = await transport.createNote({ kind, prompt, harness })
      onCreated({ kind: 'note', path })
    } catch (error) {
      setFailure(String(error))
      setWorking(false)
    }
  }

  return (
    <div className="page">
      <h1 className="page-title">New note</h1>
      <section className="card agent-card" aria-label="Write a note with an agent">
        <div className="subtabs" role="group" aria-label="Kind of note">
          {KINDS.map((k) => (
            <button
              key={k.kind}
              className="subtab"
              aria-pressed={kind === k.kind}
              disabled={working}
              onClick={() => setKind(k.kind)}
            >
              {k.label}
            </button>
          ))}
        </div>
        <p className="muted small">{current?.about}</p>
        <label className="field">
          <span>Describe the note</span>
          <textarea
            rows={6}
            value={prompt}
            disabled={working}
            onChange={(event) => setPrompt(event.target.value)}
            placeholder={current?.placeholder}
          />
        </label>
        <p className="muted small">
          {TERMINAL_LABELS[harness]} writes it with Synapse&apos;s note skills: it picks the folder,
          tags it, links to the notes that exist and opens the result here. Nothing is asked of you
          while it works.
        </p>
        <div className="row">
          <button
            className="primary"
            disabled={working || prompt.trim() === ''}
            onClick={() => void write()}
          >
            {working ? 'Writing…' : 'Write the note'}
          </button>
          {working && (
            <span className="muted small" role="status">
              An agent is writing, this can take a few minutes.
            </span>
          )}
        </div>
        {failure !== null && (
          <p className="error" role="alert">
            {failure}
          </p>
        )}
      </section>
    </div>
  )
}
