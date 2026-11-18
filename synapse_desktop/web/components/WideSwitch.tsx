// The switch beside the title of a note that shows it at the full width of the page.
export function WideSwitch({
  wide,
  onChange,
}: {
  wide: boolean
  onChange: (wide: boolean) => void
}) {
  return (
    <button
      role="switch"
      aria-checked={wide}
      aria-label="Wide note"
      title={wide ? 'Show the note at reading width' : 'Show the note at the full width'}
      className="wide-switch"
      onClick={() => onChange(!wide)}
    >
      <span className="switch-track" aria-hidden="true">
        <span className="switch-knob" />
      </span>
      <span className="small">Wide</span>
    </button>
  )
}
