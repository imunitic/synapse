import { useCallback, useMemo, useState } from 'react'
import { listSkills } from '../domain/definitions.ts'
import { formatDuration } from '../domain/format.ts'
import { layoutGraph } from '../domain/graph.ts'
import { fallThrough, mentioned, routesFrom } from '../domain/outcomes.ts'
import {
  describePipeline,
  guardLabel,
  type Instruction,
  type PipelineDescription,
  type PipelineStep,
  type Problem,
} from '../domain/pipelines.ts'
import { transport } from '../transport/index.ts'
import { useConfig } from './config.tsx'
import { RunDialog } from './RunDialog.tsx'
import { SourceCard } from './DefinitionPage.tsx'
import { GraphView } from './GraphView.tsx'
import type { Page } from './state.ts'
import { useLoad } from './useLoad.ts'

function ProblemList({ problems }: { problems: Problem[] }) {
  return (
    <section className="alert" aria-label="Problems" role="alert">
      <h2 className="card-title">This pipeline cannot run</h2>
      <ul className="problems mono">
        {problems.map((p, i) => (
          <li key={i}>
            {p.file !== null && (
              <span className="muted">
                {p.file.split(/[\\/]/).pop()}:{p.line}:{p.column}{' '}
              </span>
            )}
            {p.message}
          </li>
        ))}
      </ul>
    </section>
  )
}

function InstructionCell({
  instruction,
  skillPath,
  onOpen,
}: {
  instruction: Instruction
  skillPath: string | undefined
  onOpen: (page: Page) => void
}) {
  if (instruction === null) return <span className="muted">none</span>
  if (instruction.kind === 'prompt') return <span className="prompt">{instruction.text}</span>
  if (skillPath === undefined) {
    return <span className="mono">skill {instruction.name} (not found)</span>
  }
  const name = instruction.name
  return (
    <button
      className="link mono"
      onClick={() => onOpen({ kind: 'definition', definition: 'skill', name, path: skillPath })}
    >
      skill {name}
    </button>
  )
}

// What the step's instructions say, to look for the outcomes in: its prompts and
// the text of its skills. Null while it is read, and when a skill cannot be
// read, because then nothing can be said about it.
function useInstructionTexts(step: PipelineStep, skills: Map<string, string>): string[] | null {
  const load = useCallback(async (): Promise<string[] | null> => {
    const texts: string[] = []
    for (const instruction of [step.role, step.assignment]) {
      if (instruction === null) continue
      if (instruction.kind === 'prompt') {
        texts.push(instruction.text)
        continue
      }
      const path = skills.get(instruction.name)
      if (path === undefined) return null
      try {
        texts.push(await transport.readText(path))
      } catch {
        return null
      }
    }
    return texts
  }, [step, skills])
  const { state } = useLoad(load)
  return state.status === 'ready' ? state.data : null
}

// The outcomes a step's edges wait for, and where each leads.
function Routes({
  description,
  step,
  texts,
}: {
  description: PipelineDescription
  step: PipelineStep
  texts: string[] | null
}) {
  const routes = routesFrom(description, step.name)
  const next = fallThrough(description, step.name)
  return (
    <ul className="routes">
      {routes.map((route) => (
        <li key={route.edgeIndex}>
          <span className="mono">
            {route.outcome ?? (route.rule === null ? 'always' : `rule ${route.rule}`)}
          </span>
          <span className="muted">
            {' '}
            → {route.to}
            {route.maxIterations !== null && ` · at most ${route.maxIterations} times`}
          </span>
          {texts !== null && route.outcome !== null && !mentioned(route.outcome, texts) && (
            <span className="warn-note"> not named in this step's instructions</span>
          )}
        </li>
      ))}
      <li className="muted">otherwise → {next ?? 'the run completes'}</li>
    </ul>
  )
}

function StepDetails({
  description,
  step,
  skills,
  onOpen,
}: {
  description: PipelineDescription
  step: PipelineStep
  skills: Map<string, string>
  onOpen: (page: Page) => void
}) {
  const texts = useInstructionTexts(step, skills)
  const skillPath = (i: Instruction) => (i?.kind === 'skill' ? skills.get(i.name) : undefined)
  return (
    <section className="card" aria-label={`Step ${step.name}`}>
      <h2 className="card-title">
        Step <span className="mono accent">{step.name}</span>
      </h2>
      <dl className="facts">
        <dt>Harness</dt>
        <dd className="mono">{step.harness}</dd>
        <dt>Model</dt>
        <dd className="mono">{step.model ?? 'the harness default'}</dd>
        <dt>Permissions</dt>
        <dd className="mono">{step.permissions}</dd>
        <dt>Timeout</dt>
        <dd className="mono">{formatDuration(step.timeout_seconds)}</dd>
        <dt>Retries</dt>
        <dd className="mono">{step.retries}</dd>
        <dt>Built from</dt>
        <dd>
          {step.origins.length === 0 && <span className="muted">the step alone</span>}
          {step.origins.map((origin) => (
            <button
              key={origin.name}
              className="link mono"
              onClick={() =>
                onOpen({
                  kind: 'definition',
                  definition: origin.kind,
                  name: origin.name,
                  path: origin.file,
                })
              }
            >
              {origin.kind} {origin.name}
            </button>
          ))}
        </dd>
        <dt>Role</dt>
        <dd>
          <InstructionCell
            instruction={step.role}
            skillPath={skillPath(step.role)}
            onOpen={onOpen}
          />
        </dd>
        <dt>Assignment</dt>
        <dd>
          <InstructionCell
            instruction={step.assignment}
            skillPath={skillPath(step.assignment)}
            onOpen={onOpen}
          />
        </dd>
        <dt>Routes on</dt>
        <dd>
          <Routes description={description} step={step} texts={texts} />
        </dd>
      </dl>
    </section>
  )
}

function Edges({ description }: { description: PipelineDescription }) {
  return (
    <section className="card" aria-label="Edges and limits">
      <h2 className="card-title">Edges and limits</h2>
      {description.edges.length === 0 && <p className="muted">No edges: the steps run in order.</p>}
      <ul className="problems mono">
        {description.edges.map((edge) => (
          <li key={edge.index}>
            {edge.from} → {edge.to}
            <span className="muted">
              {' '}
              · {guardLabel(edge.guard) ?? 'always'}
              {edge.max_iterations !== null && ` · at most ${edge.max_iterations} times`}
            </span>
          </li>
        ))}
      </ul>
      <p className="muted">
        Step ceiling {description.limits.step_ceiling} · default timeout{' '}
        {formatDuration(description.limits.default_timeout_seconds)} · runner{' '}
        {description.limits.runner}
      </p>
    </section>
  )
}

// A pipeline: its steps and edges as the CLI resolves them, the step chosen,
// and the file.
export function PipelinePage({
  name,
  path,
  onOpen,
}: {
  name: string
  path: string
  onOpen: (page: Page) => void
}) {
  const load = useCallback(async () => {
    const [described, skills] = await Promise.all([
      describePipeline(transport, name),
      listSkills(transport),
    ])
    return { described, skills: new Map(skills.map((s) => [s.name, s.path])) }
  }, [name])
  const { state } = useLoad(load)
  const [chosen, setChosen] = useState<string | null>(null)
  const [running, setRunning] = useState(false)
  const { state: config } = useConfig()
  const hasWorkDir = config.status === 'ready' && config.config.workDir !== null

  const description =
    state.status === 'ready' && state.data.described.ok ? state.data.described.description : null
  const graph = useMemo(
    () => (description === null ? null : layoutGraph(description)),
    [description],
  )
  const selected = description?.steps.find((s) => s.name === chosen) ?? description?.steps[0]

  return (
    <div className="page full">
      <div className="page-head">
        <div>
          <p className="eyebrow">Pipeline</p>
          <h1 className="page-title">{name}</h1>
        </div>
        <div className="head-actions">
          <button
            className="primary"
            disabled={description === null || !hasWorkDir}
            onClick={() => setRunning(true)}
          >
            Run
          </button>
          {description !== null && !hasWorkDir && (
            <span className="muted small">Set a work directory first.</span>
          )}
        </div>
      </div>
      {running && (
        <RunDialog
          pipeline={name}
          onClose={() => setRunning(false)}
          onStarted={(id) => {
            setRunning(false)
            onOpen({ kind: 'execution', id })
          }}
        />
      )}
      {state.status === 'loading' && <p className="muted">Loading…</p>}
      {state.status === 'failed' && (
        <p role="alert">Could not describe the pipeline: {state.error}</p>
      )}
      {state.status === 'ready' && !state.data.described.ok && (
        <ProblemList problems={state.data.described.problems} />
      )}
      {state.status === 'ready' &&
        description !== null &&
        graph !== null &&
        selected !== undefined && (
          <>
            <section className="card graph-card" aria-label="Graph">
              <GraphView
                graph={graph}
                selected={selected.name}
                onSelect={setChosen}
                subtitles={Object.fromEntries(description.steps.map((s) => [s.name, s.harness]))}
              />
            </section>
            <StepDetails
              description={description}
              step={selected}
              skills={state.data.skills}
              onOpen={onOpen}
            />
            <Edges description={description} />
          </>
        )}
      <SourceCard path={path} />
    </div>
  )
}
