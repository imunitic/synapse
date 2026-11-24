import { RightSidebarIcon } from '../components/icons.tsx'

// The icon in the top right corner that opens and shuts the Changes sidebar, the counterpart of the
// icon in the top left corner for the side panel. It carries the number of changed files, so that a
// sidebar that is shut still says there is something in it. On a note page the sidebar is the
// note's outline, and the toggle says so and counts the note's review comments instead.
export function ChangesToggle({
  open,
  count,
  onToggle,
  label = 'Show or hide the changes',
  counted = 'changed',
}: {
  open: boolean
  count: number | null
  onToggle: () => void
  label?: string
  // What the count is of, after the number in the accessible name.
  counted?: string
}) {
  return (
    <button
      className="changes-toggle"
      aria-label={count === null || count === 0 ? label : `${label}: ${count} ${counted}`}
      title={label}
      aria-pressed={open}
      onClick={onToggle}
    >
      <RightSidebarIcon />
      {count !== null && count > 0 && (
        <span className="changes-badge" aria-hidden="true">
          {count > 99 ? '99+' : count}
        </span>
      )}
    </button>
  )
}
