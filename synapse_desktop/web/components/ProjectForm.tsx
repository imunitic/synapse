import { useState } from 'react'
import { transport } from '../transport/index.ts'

// A new project: its name, which is the folder its notes are in, and its prefix, which
// starts the id of each note. The server checks both and refuses one that is taken.
export function AddProjectForm({
  onAdded,
  onCancel,
}: {
  // The name of the project that was added.
  onAdded: (name: string) => void
  onCancel?: () => void
}) {
  const [name, setName] = useState('')
  const [prefix, setPrefix] = useState('')
  const [problem, setProblem] = useState<string | null>(null)

  async function add(event: React.SubmitEvent<HTMLFormElement>) {
    event.preventDefault()
    try {
      await transport.addProject(name.trim(), prefix.trim())
      onAdded(name.trim())
      setName('')
      setPrefix('')
      setProblem(null)
    } catch (error) {
      setProblem(String(error).replace(/^Error: /, ''))
    }
  }

  return (
    <>
      <form className="row" aria-label="New project" onSubmit={(event) => void add(event)}>
        <input
          aria-label="Project name"
          placeholder="name, as the folder"
          value={name}
          onChange={(event) => setName(event.target.value)}
        />
        <input
          aria-label="Project prefix"
          placeholder="prefix, as in sb"
          value={prefix}
          onChange={(event) => setPrefix(event.target.value)}
        />
        <button
          className="secondary"
          type="submit"
          disabled={name.trim() === '' || prefix.trim() === ''}
        >
          Add
        </button>
        {onCancel !== undefined && (
          <button className="link" type="button" onClick={onCancel}>
            Cancel
          </button>
        )}
      </form>
      {problem !== null && (
        <p className="error" role="alert">
          {problem}
        </p>
      )}
    </>
  )
}
