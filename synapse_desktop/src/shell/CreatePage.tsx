import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { listDefinitions, listSkills } from '../domain/definitions.ts'
import {
  declaredOf,
  marksFor,
  previewDraft,
  skillProblems,
  templateFor,
  type Declared,
  type Preview,
} from '../domain/drafts.ts'
import { layoutGraph } from '../domain/graph.ts'
import type { PipelineDescription, Problem } from '../domain/pipelines.ts'
import { parseSkillMeta } from '../domain/skills.ts'
import { transport } from '../transport/index.ts'
import { AgentCard } from './AgentCard.tsx'
import { CodeEditor } from './CodeEditor.tsx'
import { GraphView } from './GraphView.tsx'
import { DEFINITION_LABELS, type DefinitionKind, type Page } from './state.ts'
import { useLoad } from './useLoad.ts'

const DEBOUNCE_MS = 300

// The names that are taken: definitions share one namespace, and skills have
// their own.
function loadConfig() {
  return transport.getConfig()
}

async function loadTaken() {
  const [definitions, skills] = await Promise.all([
    listDefinitions(transport),
    listSkills(transport),
  ])
  return {
    definitions: new Set(definitions.map((d) => d.name)),
    skills: new Set(skills.map((s) => s.name)),
    existing: {
      definitions: definitions.map((d) => ({ name: d.name, kind: d.kind })),
      skills: skills.map((s) => s.name),
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

// A new definition: its text is written in an editor, the program says what is
// wrong as it is written, and a pipeline is drawn as it stands.
export function CreatePage({
  definition,
  onCreated,
  onCancel,
}: {
  definition: DefinitionKind
  onCreated: (page: Page) => void
  onCancel: () => void
}) {
  const isSkill = definition === 'skill'
  const initial = useMemo(() => templateFor(definition), [definition])
  const [text, setText] = useState(initial)
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [replacement, setReplacement] = useState<{ id: number; text: string } | null>(null)
  const [mode, setMode] = useState<'hand' | 'agent'>('hand')
  const { state: taken } = useLoad(loadTaken)
  const { state: config } = useLoad(loadConfig)

  const declared = isSkill ? null : declaredOf(text)
  const name = isSkill ? parseSkillMeta(text).name : (declared?.name ?? null)
  const { answer, failure, lastGood } = usePreview(text, declared)
  const current = answer !== null && answer.text === text ? answer : null
  const checking = !isSkill && declared !== null && current === null && failure === null

  const problems: Problem[] = []
  if (isSkill) problems.push(...skillProblems(text))
  else if (declared === null) {
    problems.push({
      severity: 'error',
      file: null,
      line: null,
      column: null,
      message: 'The text must start with Pipeline, System or Agent and a name.',
    })
  } else if (current !== null) problems.push(...current.preview.problems)

  const takenNow =
    taken.status === 'ready' &&
    name !== null &&
    (isSkill ? taken.data.skills : taken.data.definitions).has(name)
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
  const graph = useMemo(() => (lastGood === null ? null : layoutGraph(lastGood)), [lastGood])
  const canSave =
    name !== null &&
    !checking &&
    !saving &&
    failure === null &&
    problems.length === 0 &&
    taken.status === 'ready'

  const onChange = useCallback((next: string) => {
    setText(next)
    setSaveError(null)
  }, [])

  async function save() {
    if (name === null) return
    setSaving(true)
    setSaveError(null)
    try {
      const { path } = await transport.writeDefinition(
        isSkill ? { kind: 'skill', name, text } : { kind: 'definition', name, text },
      )
      onCreated({
        kind: 'definition',
        definition: isSkill ? 'skill' : (declared?.kind ?? definition),
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
          <p className="eyebrow">Create</p>
          <h1 className="page-title">New {DEFINITION_LABELS[definition].singular}</h1>
        </div>
      </div>

      <section className="card" aria-label="Name">
        <h2 className="card-title">Name</h2>
        <p className="mono name-value">{name ?? 'Not named yet.'}</p>
        <p className="muted small">
          {name === null
            ? 'The name comes from the text.'
            : isSkill
              ? `The name is in the frontmatter: skills/${name}/SKILL.md.`
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
          Build with an agent
        </button>
      </div>

      {mode === 'agent' && (
        <AgentCard
          definition={definition}
          existing={taken.status === 'ready' ? taken.data.existing : null}
          defaultHarness={
            config.status === 'ready' ? (config.data.defaultHarness ?? 'Claude') : 'Claude'
          }
          onWritten={(written) => setReplacement((r) => ({ id: (r?.id ?? 0) + 1, text: written }))}
        />
      )}

      {!isSkill && declared?.kind === 'pipeline' && (
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
          highlight={!isSkill}
          replacement={replacement}
        />
        {checking && <p className="muted small">Checking…</p>}
      </section>

      <section
        className={problems.length > 0 ? 'alert' : 'card'}
        aria-label="Problems"
        role={problems.length > 0 ? 'alert' : undefined}
      >
        <h2 className="card-title">
          {problems.length > 0 ? 'To fix before it can be created' : 'Problems'}
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
          {saving ? 'Saving…' : 'Create'}
        </button>
      </div>
    </div>
  )
}
