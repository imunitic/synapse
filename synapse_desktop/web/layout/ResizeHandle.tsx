import type { ResizableWidth } from './use-resizable-width.ts'

// The strip on a panel's edge that resizes it: dragged with the pointer, moved with the arrow keys
// while it has focus, and put back to the starting width with a double click.
export function ResizeHandle({
  className,
  label,
  handleProps,
}: {
  className: string
  label: string
  handleProps: ResizableWidth['handleProps']
}) {
  return (
    <div
      className={className}
      role="separator"
      aria-orientation="vertical"
      tabIndex={0}
      aria-label={label}
      {...handleProps}
    />
  )
}
