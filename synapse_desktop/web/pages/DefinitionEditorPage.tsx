import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { listDefinitions } from '../domain/definitions.ts'
import {
  declaredOf,
  isDefinitionName,
  marksFor,
  previewDraft,
  renameDeclared,
  templateFor,
  type Declared,
  type Preview,
} from '../domain/drafts.ts'
import { layoutGraph } from '../domain/graph.ts'
import type { PipelineDescription, Problem } from '../domain/pipelines.ts'
import { transport } from '../transport/index.ts'
import { AgentCard } from '../components/AgentCard.tsx'
import { DslReference } from '../components/DslReference.tsx'
import { CodeEditor } from '../components/CodeEditor.tsx'
import { GraphView } from '../components/GraphView.tsx'
import { measureGraphText } from '../components/measure-text.ts'
import { DEFINITION_LABELS, type DefinitionKind, type Page } from '../state/state.ts'
import { useLoad } from '../state/useLoad.ts'

const DEBOUNCE_MS = 300

// The names that are taken: every kind of definition shares one namespace.
async function loadTaken() {
  const definitions = await listDefinitions(transport)
  return {
    definitions: new Set(definitions.map((d) => d.name)),
    existing: {
      definitions: definitions.map((d) => ({ name: d.name, kind: d.kind })),
    },
  }
}

interface Answer {
  text: string
  preview: Preview
}

// What the program says about the text, a moment after it stops changing. The
// answer carries the text it is for, so an answer to text that has changed since
// is not taken for an answer to the text there is now.
function usePreview(text: string, target: Declared | null) {
  const [answer, setAnswer] = useState<Answer | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [lastGood, setLastGood] = useState<PipelineDescription | null>(null)
  const latest = useRef(0)
  const kind = target?.kind
  const name = target?.name

  useEffect(() => {
    if (kind === undefined || name === undefined) return
    const mine = ++latest.current
    const timer = setTimeout(() => {
      previewDraft(transport, text, { kind, name })
        .then((preview) => {
          if (latest.current !== mine) return
          setAnswer({ text, preview })
          setFailure(null)
          if (preview.description !== null) setLastGood(preview.description)
        })
        .catch((error: unknown) => {
          if (latest.current === mine) setFailure(String(error))
        })
    }, DEBOUNCE_MS)
    return () => clearTimeout(timer)
  }, [text, kind, name])

  return { answer, failure, lastGood }
}

function ProblemList({ problems }: { problems: Problem[] }) {
  return (
    <ul className="problems mono">
      {problems.map((p, i) => (
        <li key={i}>
          {p.line !== null && (
            <span className="muted">
              line {p.line}:{p.column}{' '}
            </span>
          )}
          {p.message}
        </li>
      ))}
    </ul>
  )
}

function problem(message: string): Problem {
  return { severity: 'error', file: null, line: null, column: null, message }
}

// The text of a definition, written in an editor: a new one, or one that
// exists. The program says what is wrong as it is written, and a pipeline is
// drawn as it stands. An existing definition keeps its name and its kind.
export function DefinitionEditorPage({
  definition,
  existing,
  onCreated,
  onSaved,
  onCancel,
}: {
  definition: DefinitionKind
  // The definition being changed, with its text as it was read.
  existing?: { name: string; path: string; text: string }
  onCreated: (page: Page) => void
  onSaved: () => void
  onCancel: () => void
}) {
  const initial = useMemo(() => existing?.text ?? templateFor(definition), [definition, existing])
  const [text, setText] = useState(initial)
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [replacement, setReplacement] = useState<{ id: number; text: string } | null>(null)
  const [mode, setMode] = useState<'hand' | 'agent'>('hand')
  // What is typed in the name field while it is not a name yet: a name that fits
  // is put into the text at once, and then the text is what the field shows.
  const [nameDraft, setNameDraft] = useState<string | null>(null)
  const { state: taken } = useLoad(loadTaken)

  const declared = declaredOf(text)
  const name = declared?.name ?? null
  // What the program is asked about: the file's own name and kind when it exists,
  // so that a text that says otherwise shows up as a problem.
  const target = existing ? { kind: definition, name: existing.name } : declared
  const { answer, failure, lastGood } = usePreview(text, target)
  const current = answer !== null && answer.text === text ? answer : null
  const checking = target !== null && current === null && failure === null

  const problems: Problem[] = []
  if (declared === null) {
    problems.push(problem('The text must start with Pipeline, System, Agent or Prompt and a name.'))
  } else if (existing && declared.name !== existing.name) {
    problems.push(
      problem(`The name of this file is ${existing.name}, and the text names it ${declared.name}.`),
    )
  } else if (existing && declared.kind !== definition) {
    problems.push(
      problem(
        `This is ${DEFINITION_LABELS[definition].singular} ${existing.name} and cannot become another kind.`,
      ),
    )
  } else if (current !== null) problems.push(...current.preview.problems)

  const takenNow =
    !existing && taken.status === 'ready' && name !== null && taken.data.definitions.has(name)
  if (takenNow) {
    problems.push({
      severity: 'error',
      file: null,
      line: null,
      column: null,
      message: `A ${DEFINITION_LABELS[definition].singular} named ${name} already exists.`,
    })
  }

  const marks = useMemo(
    () => (current === null ? [] : marksFor(text, current.preview.problems)),
    [current, text],
  )
  const graph = useMemo(
    () => (lastGood === null ? null : layoutGraph(lastGood, measureGraphText)),
    [lastGood],
  )
  const canSave =
    name !== null &&
    !checking &&
    !saving &&
    failure === null &&
    problems.length === 0 &&
    (existing ? text !== existing.text : taken.status === 'ready')

  const onChange = useCallback((next: string) => {
    setText(next)
    setSaveError(null)
    setNameDraft(null)
  }, [])

  // The name field changes the name in the text, a name at a time that fits.
  function rename(next: string) {
    if (!isDefinitionName(next)) {
      setNameDraft(next)
      return
    }
    setNameDraft(null)
    const renamed = renameDeclared(text, next)
    if (renamed !== text) setReplacement((r) => ({ id: (r?.id ?? 0) + 1, text: renamed }))
  }

  async function save() {
    if (name === null) return
    setSaving(true)
    setSaveError(null)
    try {
      if (existing) {
        await transport.saveDefinition(existing.path, existing.text, text)
        onSaved()
        return
      }
      const { path } = await transport.writeDefinition({ kind: 'definition', name, text })
      onCreated({
        kind: 'definition',
        definition: declared?.kind ?? definition,
        name,
        path,
      })
    } catch (error) {
      setSaveError(String(error))
      setSaving(false)
    }
  }

  return (
    <div className="page full">
      <div className="page-head">
        <div>
          <p className="eyebrow">{existing ? 'Edit' : 'Create'}</p>
          <h1 className="page-title">
            {existing ? existing.name : `New ${DEFINITION_LABELS[definition].singular}`}
          </h1>
        </div>
      </div>

      <section className="card" aria-label="Name">
        <h2 className="card-title">Name</h2>
        {existing ? (
          <p className="mono name-value">{existing.name}</p>
        ) : (
          <input
            className="mono name-input"
            aria-label="Name"
            value={nameDraft ?? name ?? ''}
            placeholder="Name_Of_The_Definition"
            onChange={(event) => rename(event.target.value)}
          />
        )}
        <p className="muted small">
          {existing
            ? 'The name cannot change: it is the name of the file.'
            : nameDraft !== null
              ? 'A name has letters, digits and underscores and starts with a letter.'
              : name === null
                ? 'The name is in the text: type it here or write it there.'
                : `The name is the file name: ${name}.synapse.`}
        </p>
      </section>

      <div className="row" role="group" aria-label="How to write it">
        <button
          className={mode === 'hand' ? 'primary' : 'secondary'}
          aria-pressed={mode === 'hand'}
          onClick={() => setMode('hand')}
        >
          Write by hand
        </button>
        <button
          className={mode === 'agent' ? 'primary' : 'secondary'}
          aria-pressed={mode === 'agent'}
          onClick={() => setMode('agent')}
        >
          {existing ? 'Revise with an agent' : 'Build with an agent'}
        </button>
      </div>

      {mode === 'agent' && (
        <AgentCard
          definition={definition}
          current={existing ? text : undefined}
          existing={taken.status === 'ready' ? taken.data.existing : null}
          onWritten={(written) => setReplacement((r) => ({ id: (r?.id ?? 0) + 1, text: written }))}
        />
      )}

      {declared?.kind === 'pipeline' && (
        <section className="card graph-card" aria-label="Diagram">
          {graph === null ? (
            <p className="muted diagram-note">
              The diagram appears as soon as the pipeline is valid.
            </p>
          ) : (
            <>
              {problems.length > 0 && (
                <p className="muted small diagram-note">
                  Showing the last valid version of the text.
                </p>
              )}
              <GraphView
                graph={graph}
                subtitles={Object.fromEntries(
                  (lastGood?.steps ?? []).map((s) => [s.name, s.harness]),
                )}
              />
            </>
          )}
        </section>
      )}

      <section className="card" aria-label="Editor">
        <CodeEditor
          initial={initial}
          onChange={onChange}
          marks={marks}
          label={`Text of the new ${DEFINITION_LABELS[definition].singular}`}
          replacement={replacement}
        />
        {checking && <p className="muted small">Checking…</p>}
      </section>

      <DslReference kind={definition} />

      <section
        className={problems.length > 0 ? 'alert' : 'card'}
        aria-label="Problems"
        role={problems.length > 0 ? 'alert' : undefined}
      >
        <h2 className="card-title">
          {problems.length > 0
            ? `To fix before it can be ${existing ? 'saved' : 'created'}`
            : 'Problems'}
        </h2>
        {failure !== null && <p>The program could not be asked: {failure}</p>}
        {failure === null && problems.length === 0 && (
          <p className="muted">{checking ? 'Checking…' : 'None.'}</p>
        )}
        <ProblemList problems={problems} />
        {saveError !== null && <p className="error">{saveError}</p>}
      </section>

      <div className="row actions">
        <button className="secondary" onClick={onCancel}>
          Cancel
        </button>
        <button className="primary" disabled={!canSave} onClick={() => void save()}>
          {saving ? 'Saving…' : existing ? 'Save' : 'Create'}
        </button>
      </div>
    </div>
  )
}
