import { RightSidebarIcon } from '../components/icons.tsx'

// The icon in the top right corner that opens and shuts the Changes sidebar, the counterpart of the
// icon in the top left corner for the side panel. It carries the number of changed files, so that a
// sidebar that is shut still says there is something in it.
export function ChangesToggle({
  open,
  count,
  onToggle,
}: {
  open: boolean
  count: number | null
  onToggle: () => void
}) {
  const label = 'Show or hide the changes'
  return (
    <button
      className="changes-toggle"
      aria-label={count === null || count === 0 ? label : `${label}: ${count} changed`}
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
