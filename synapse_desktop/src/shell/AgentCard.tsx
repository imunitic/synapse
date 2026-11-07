import { useState } from 'react'
import type { Harness } from '../../shared/transport.ts'
import type { Definition } from '../domain/definitions.ts'
import { transport } from '../transport/index.ts'
import { DEFINITION_LABELS, type DefinitionKind } from './state.ts'

const HARNESSES: readonly Harness[] = ['Claude', 'Codex', 'Opencode']

// Describe what is wanted and have an agent write the text, which goes into the
// editor to be read, changed and checked like any other text.
export function AgentCard({
  definition,
  existing,
  defaultHarness,
  onWritten,
}: {
  definition: DefinitionKind
  // What exists, or null until it has been read.
  existing: { definitions: Pick<Definition, 'name' | 'kind'>[]; skills: string[] } | null
  defaultHarness: Harness
  onWritten: (text: string) => void
}) {
  const [prompt, setPrompt] = useState('')
  // What the person chose; until they do, the default harness.
  const [chosen, setChosen] = useState<Harness | null>(null)
  const harness = chosen ?? defaultHarness
  const [working, setWorking] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  const label = DEFINITION_LABELS[definition].singular

  async function generate() {
    if (existing === null) return
    setWorking(true)
    setFailure(null)
    try {
      const { text } = await transport.generateDefinition({
        kind: definition,
        prompt,
        harness,
        definitions: existing.definitions.map((d) => ({ name: d.name, kind: d.kind })),
        skills: existing.skills,
      })
      onWritten(text)
    } catch (error) {
      setFailure(String(error))
    } finally {
      setWorking(false)
    }
  }

  return (
    <section className="card agent-card" aria-label="Build with an agent">
      <label className="field">
        <span>Describe what it should do</span>
        <textarea
          rows={4}
          value={prompt}
          disabled={working}
          onChange={(e) => setPrompt(e.target.value)}
          placeholder={`What should the ${label} do?`}
        />
      </label>
      <p className="muted small">
        The text the agent writes replaces what is in the editor; undo brings back what was there.
      </p>
      <div className="row">
        <label className="row">
          <span>Harness</span>
          <select
            value={harness}
            disabled={working}
            onChange={(e) => setChosen(e.target.value as Harness)}
          >
            {HARNESSES.map((h) => (
              <option key={h}>{h}</option>
            ))}
          </select>
        </label>
        <button
          className="primary"
          disabled={working || prompt.trim() === '' || existing === null}
          onClick={() => void generate()}
        >
          {working ? 'Building…' : 'Build'}
        </button>
        {working && (
          <span className="muted small">An agent is writing, this can take a minute.</span>
        )}
      </div>
      {failure !== null && <p className="error">{failure}</p>}
    </section>
  )
}
