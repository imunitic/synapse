import { useRef, useState, type KeyboardEvent, type PointerEvent } from 'react'
import { clampWidth, readStoredWidth, stepWidth, type WidthLimits } from '../domain/panel-width.ts'

export interface ResizableWidth {
  width: number
  handleProps: {
    onPointerDown: (event: PointerEvent<HTMLDivElement>) => void
    onPointerMove: (event: PointerEvent<HTMLDivElement>) => void
    onPointerUp: () => void
    onPointerCancel: () => void
    onDoubleClick: () => void
    onKeyDown: (event: KeyboardEvent<HTMLDivElement>) => void
    'aria-valuenow': number
    'aria-valuemin': number
    'aria-valuemax': number
  }
}

function readKept(key: string, limits: WidthLimits): number {
  try {
    return readStoredWidth(localStorage.getItem(key), limits)
  } catch {
    return limits.initial
  }
}

function keep(key: string, width: number): void {
  try {
    localStorage.setItem(key, String(width))
  } catch {
    // Not kept.
  }
}

// The width of the main page now, which keeps at least MAIN_MIN_PX while a panel widens.
function mainWidth(): number {
  const main = document.querySelector('main.main')
  return main === null ? Infinity : main.getBoundingClientRect().width
}

// The width of a panel a person resizes by dragging the handle on its edge, with the arrow keys
// while the handle has focus, or back to `initial` with a double click. `edge` is the side the
// panel grows from: 'right' for a sidebar on the right of the window, 'left' for a panel on its
// left. The width is kept in local storage under `key` when a drag ends and after a key press or a
// double click, never on each pointer move. `min` and `max` may change between renders.
export function useResizableWidth(options: {
  key: string
  min: number
  max: number
  initial: number
  edge: 'left' | 'right'
}): ResizableWidth {
  const { key, edge } = options
  const limits: WidthLimits = { min: options.min, max: options.max, initial: options.initial }
  const [stored, setStored] = useState(() => readKept(key, limits))
  const width = Math.min(limits.max, Math.max(limits.min, stored))
  const dragging = useRef<HTMLElement | null>(null)
  const latest = useRef(width)
  latest.current = width

  const set = (next: number, persist: boolean) => {
    latest.current = next
    setStored(next)
    if (persist) keep(key, next)
  }

  const onPointerDown = (event: PointerEvent<HTMLDivElement>) => {
    dragging.current = event.currentTarget.parentElement ?? event.currentTarget
    event.currentTarget.setPointerCapture(event.pointerId)
  }
  const onPointerMove = (event: PointerEvent<HTMLDivElement>) => {
    const panel = dragging.current
    if (panel === null) return
    const wanted =
      edge === 'right'
        ? window.innerWidth - event.clientX
        : event.clientX - panel.getBoundingClientRect().left
    set(clampWidth(wanted, limits, { current: latest.current, mainWidth: mainWidth() }), false)
  }
  const endDrag = () => {
    if (dragging.current === null) return
    dragging.current = null
    keep(key, latest.current)
  }
  const onDoubleClick = () => set(limits.initial, true)
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
    event.preventDefault()
    const towardsLeft = event.key === 'ArrowLeft'
    // A sidebar on the right widens towards the left; a panel on the left widens towards the right.
    const direction = towardsLeft === (edge === 'right') ? 1 : -1
    set(stepWidth(latest.current, direction, event.shiftKey, limits, mainWidth()), true)
  }

  return {
    width,
    handleProps: {
      onPointerDown,
      onPointerMove,
      onPointerUp: endDrag,
      onPointerCancel: endDrag,
      onDoubleClick,
      onKeyDown,
      'aria-valuenow': Math.round(width),
      'aria-valuemin': limits.min,
      'aria-valuemax': limits.max,
    },
  }
}
