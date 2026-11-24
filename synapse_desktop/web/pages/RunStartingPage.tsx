import type { TerminalSession } from '../state/state.ts'

// The page of an interactive run between its start and its name: the run is named once it has
// begun, and then this page gives way to the page of the run.
export function RunStartingPage({
  session,
  onDismiss,
}: {
  session: TerminalSession | undefined
  onDismiss: () => void
}) {
  const name = session?.pipeline ?? session?.title ?? 'the run'
  if (session === undefined || session.ended === true) {
    return (
      <section>
        <p role="alert">The run did not start.</p>
        <button type="button" onClick={onDismiss}>
          Close
        </button>
      </section>
    )
  }
  return (
    <section>
      <p role="status">Starting {name}…</p>
    </section>
  )
}
