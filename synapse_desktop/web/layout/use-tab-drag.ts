import { useRef, useState, type PointerEvent, type RefObject } from 'react'
import { indexAfterMove, insertionAt } from '../domain/tabs.ts'

// How far the pointer moves before a press on a tab becomes a drag, so that a click stays a click.
const DRAG_THRESHOLD_PX = 4

// Dragging the tabs of one row into another order. It follows the pointer and not the browser's
// drag and drop, which the desktop window keeps for files dropped on it. A press past a few pixels
// is a drag, which ends with no move on Escape, or when the pointer is let go off the row.
// `ids` are the tabs left to right; each tab is a direct child of `row` that matches `tabSelector`.
// No tab goes before the index `first`, for a row whose first tabs are pinned.
export function useTabDrag({
  row,
  tabSelector,
  ids,
  first = 0,
  onMove,
}: {
  row: RefObject<HTMLElement | null>
  tabSelector: string
  ids: readonly string[]
  first?: number
  onMove: (id: string, to: number) => void
}) {
  const [dragging, setDragging] = useState<string | null>(null)
  const [drop, setDrop] = useState<number | null>(null)
  // The latest list, for a drag that began before the list changed.
  const current = useRef(ids)
  current.current = ids

  function press(event: PointerEvent<HTMLElement>, id: string) {
    if (event.button !== 0 || (event.target as Element).closest('input, .icon-button') !== null) {
      return
    }
    const startX = event.clientX
    const from = current.current.indexOf(id)
    let active = false
    let point: number | null = null

    function locate(x: number, y: number): number | null {
      const element = row.current
      if (element === null) return null
      const box = element.getBoundingClientRect()
      if (y < box.top || y > box.bottom) return null
      const spans = [...element.querySelectorAll<HTMLElement>(tabSelector)].map((tab) => {
        const rect = tab.getBoundingClientRect()
        return { left: rect.left, width: rect.width }
      })
      return insertionAt(spans, x, first)
    }
    function move(moved: globalThis.PointerEvent) {
      if (!active) {
        if (Math.abs(moved.clientX - startX) < DRAG_THRESHOLD_PX) return
        active = true
        setDragging(id)
      }
      point = locate(moved.clientX, moved.clientY)
      setDrop(point)
    }
    function stop(commit: boolean) {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      window.removeEventListener('pointercancel', cancel)
      window.removeEventListener('keydown', key)
      if (commit && active && point !== null && indexAfterMove(from, point) !== from) {
        onMove(id, indexAfterMove(from, point))
      }
      setDragging(null)
      setDrop(null)
    }
    function up(released: globalThis.PointerEvent) {
      if (active) point = locate(released.clientX, released.clientY)
      stop(true)
    }
    function cancel() {
      stop(false)
    }
    function key(pressed: KeyboardEvent) {
      if (pressed.key === 'Escape') stop(false)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
    window.addEventListener('pointercancel', cancel)
    window.addEventListener('keydown', key)
  }

  // Where the marker shows: only a drop that would move the tab.
  const from = dragging === null ? -1 : ids.indexOf(dragging)
  const marked = drop !== null && from !== -1 && indexAfterMove(from, drop) !== from ? drop : null

  // The marker a tab shows: a line before it, or after the last one.
  function markOf(index: number): 'before' | 'after' | undefined {
    if (marked === index) return 'before'
    if (marked === ids.length && index === ids.length - 1) return 'after'
    return undefined
  }

  return { dragging, press, markOf }
}
