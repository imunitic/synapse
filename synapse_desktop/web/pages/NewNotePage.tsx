import { useCallback, useState } from 'react'
import type { NoteKind } from '../../shared/transport.ts'
import { transport } from '../transport/index.ts'
import { RunChoice, useRunChoice } from '../components/RunChoice.tsx'
import { AddProjectForm } from '../components/ProjectForm.tsx'
import { TERMINAL_LABELS, type Page } from '../state/state.ts'
import { useLoad } from '../state/useLoad.ts'

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

// The project of a task or design note: one of this machine's projects, or the one
// the agent matches to the description. A project is made here, by a person, and never
// by the agent.
function ProjectChoice({
  value,
  onChange,
  disabled,
}: {
  value: string
  onChange: (name: string) => void
  disabled: boolean
}) {
  const load = useCallback(() => transport.listProjects(), [])
  const { state, reload } = useLoad(load)
  const [adding, setAdding] = useState(false)
  const projects = state.status === 'ready' ? state.data.projects : []

  return (
    <div className="project-choice">
      <label className="field">
        <span>Project</span>
        <select
          aria-label="Project of the note"
          value={value}
          disabled={disabled}
          onChange={(event) => onChange(event.target.value)}
        >
          <option value="">Let the agent decide</option>
          {projects.map((project) => (
            <option key={project.name} value={project.name}>
              {project.name} ({project.prefix})
            </option>
          ))}
        </select>
      </label>
      {!adding && (
        <button className="link" disabled={disabled} onClick={() => setAdding(true)}>
          New project…
        </button>
      )}
      {adding && (
        <AddProjectForm
          onAdded={(name) => {
            reload()
            onChange(name)
            setAdding(false)
          }}
          onCancel={() => setAdding(false)}
        />
      )}
    </div>
  )
}

// Describe a note and have an agent write it into the vault the way the vault's
// own commands do; the note opens when it is written.
export function NewNotePage({ onCreated }: { onCreated: (page: Page) => void }) {
  const { harness, model, chooseHarness, chooseModel } = useRunChoice()
  const [kind, setKind] = useState<NoteKind>('note')
  const [project, setProject] = useState('')
  const [prompt, setPrompt] = useState('')
  const [working, setWorking] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  const current = KINDS.find((k) => k.kind === kind) ?? KINDS[0]

  async function write() {
    setWorking(true)
    setFailure(null)
    try {
      const { path } = await transport.createNote({
        kind,
        prompt,
        harness,
        ...(model === null ? {} : { model }),
        ...(kind !== 'note' && project !== '' ? { project } : {}),
      })
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
        {kind !== 'note' && (
          <ProjectChoice value={project} onChange={setProject} disabled={working} />
        )}
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
        <RunChoice
          harness={harness}
          model={model}
          onHarness={chooseHarness}
          onModel={chooseModel}
          disabled={working}
        />
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
