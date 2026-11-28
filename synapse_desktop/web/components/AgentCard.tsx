import { useState } from 'react'
import type { Definition } from '../domain/definitions.ts'
import { transport } from '../transport/index.ts'
import { RunChoice, useRunChoice } from './RunChoice.tsx'
import { WorkingLine, useRun } from './WorkingLine.tsx'
import { DEFINITION_LABELS, type DefinitionKind } from '../state/state.ts'

// Describe what is wanted and have an agent write the text, which goes into the
// editor to be read, changed and checked like any other text.
export function AgentCard({
  definition,
  existing,
  current,
  onWritten,
}: {
  definition: DefinitionKind
  // What exists, or null until it has been read.
  existing: { definitions: Pick<Definition, 'name' | 'kind'>[] } | null
  // The text to change; absent when the definition is to be written new.
  current?: string
  onWritten: (text: string) => void
}) {
  const [prompt, setPrompt] = useState('')
  const { harness, model, effort, chooseHarness, chooseModel, chooseEffort } = useRunChoice()
  const [working, setWorking] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  const run = useRun()
  const label = DEFINITION_LABELS[definition].singular

  async function generate() {
    if (existing === null) return
    setWorking(true)
    setFailure(null)
    const runId = run.begin()
    try {
      const { text } = await transport.generateDefinition({
        run: runId,
        kind: definition,
        prompt,
        harness,
        ...(model === null ? {} : { model }),
        ...(effort === null ? {} : { effort }),
        current,
        definitions: existing.definitions.map((d) => ({ name: d.name, kind: d.kind })),
      })
      onWritten(text)
    } catch (error) {
      setFailure(String(error))
    } finally {
      setWorking(false)
      run.end()
    }
  }

  return (
    <section className="card agent-card" aria-label="Build with an agent">
      <label className="field">
        <span>
          {current === undefined ? 'Describe what it should do' : 'Describe what to change'}
        </span>
        <textarea
          rows={4}
          value={prompt}
          disabled={working}
          onChange={(e) => setPrompt(e.target.value)}
          placeholder={
            current === undefined ? `What should the ${label} do?` : `What should change in it?`
          }
        />
      </label>
      <p className="muted small">
        {current === undefined
          ? 'The text the agent writes replaces what is in the editor; undo brings back what was there.'
          : 'The agent is given the text as it is in the editor now, and the text it writes replaces it; undo brings back what was there.'}
      </p>
      <div className="row">
        <RunChoice
          harness={harness}
          model={model}
          effort={effort}
          onHarness={chooseHarness}
          onModel={chooseModel}
          onEffort={chooseEffort}
          disabled={working}
        />
        <button
          className="primary"
          disabled={working || prompt.trim() === '' || existing === null}
          onClick={() => void generate()}
        >
          {working ? 'Building…' : 'Build'}
        </button>
      </div>
      {working && run.startedAt !== null && (
        <WorkingLine
          harness={harness}
          startedAt={run.startedAt}
          doing="writing the text"
          stopping={run.stopping}
          onStop={run.stop}
        />
      )}
      {failure !== null && <p className="error">{failure}</p>}
    </section>
  )
}
