import { useEffect, useRef, useState, type Dispatch, type PointerEvent } from 'react'
import { CloseIcon } from '../components/icons.tsx'
import { listExecutions } from '../domain/executions.ts'
import { closeWarning, firstMovableIndex, indexAfterMove, insertionAt } from '../domain/tabs.ts'
import { pageTitle, type Action, type ShellState, type Tab } from '../state/state.ts'
import { transport } from '../transport/index.ts'

// The page that is always there, first, and is not closed.
const HOME = 'home'

// How far the pointer moves before a press on a tab becomes a drag, so that a click stays a click.
const DRAG_THRESHOLD_PX = 4

// What a close that has to ask is asking about.
interface Asking {
  id: string
  title: string
  warning: string
}

// The tabs of the open pages. They are put in another order by dragging them, or with Alt and
// the arrow keys; the Home tab is first and stays there. Dragging follows the pointer and not the
// browser's drag and drop, which the desktop window keeps for files dropped on it. A tab is closed with its button or a
// middle click, which asks first when that would cut something short.
export function TabBar({
  state,
  dispatch,
  waiting,
}: {
  state: ShellState
  dispatch: Dispatch<Action>
  // The interactive runs that wait for a person, by id, with what their agent said.
  waiting: ReadonlyMap<string, string>
}) {
  const ids = state.tabs.map((t) => t.id)
  // The tab being dragged, and the place between tabs it would be dropped at.
  const [dragging, setDragging] = useState<string | null>(null)
  const [drop, setDrop] = useState<number | null>(null)
  const [asking, setAsking] = useState<Asking | null>(null)
  const bar = useRef<HTMLDivElement>(null)

  // The tab that is showing is in view, however many others there are.
  useEffect(() => {
    bar.current
      ?.querySelector('.tab[data-selected="true"]')
      ?.scrollIntoView?.({ inline: 'nearest', block: 'nearest' })
  }, [state.activeId, state.tabs.length])

  async function requestClose(tab: Tab) {
    if (tab.id === HOME) return
    const runs =
      tab.page.kind === 'execution' ? await listExecutions(transport).catch(() => []) : []
    const warning = closeWarning(tab.page, state.terminals, runs)
    if (warning === null) {
      dispatch({ type: 'closeTab', id: tab.id })
    } else {
      setAsking({ id: tab.id, title: pageTitle(tab.page), warning })
    }
  }

  function finish() {
    setDragging(null)
    setDrop(null)
  }

  // A press on a tab that may move: past a few pixels it is a drag, which follows the pointer
  // wherever it goes until it is let go, and ends with no move on Escape or off the bar.
  function press(event: PointerEvent<HTMLElement>, id: string) {
    if (event.button !== 0 || (event.target as Element).closest('.icon-button') !== null) return
    const startX = event.clientX
    const from = ids.indexOf(id)
    const first = firstMovableIndex(ids)
    let active = false
    let point: number | null = null

    function locate(x: number, y: number): number | null {
      const element = bar.current
      if (element === null) return null
      const box = element.getBoundingClientRect()
      if (y < box.top || y > box.bottom) return null
      const spans = [...element.querySelectorAll<HTMLElement>(':scope > .tab')].map((tab) => {
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
        dispatch({ type: 'moveTab', id, to: indexAfterMove(from, point) })
      }
      finish()
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

  return (
    <>
      <div
        ref={bar}
        className="tabbar"
        role="tablist"
        aria-label="Open pages"
        onWheel={(event) => {
          // The wheel turns up and down, and the bar goes sideways.
          if (Math.abs(event.deltaY) > Math.abs(event.deltaX)) {
            event.currentTarget.scrollLeft += event.deltaY
          }
        }}
      >
        {state.tabs.map((tab, index) => {
          const selected = tab.id === state.activeId
          const pinned = tab.id === HOME
          const title = pageTitle(tab.page)
          // A tab shows a person is wanted in what it holds: the terminals, or the run.
          const wanted =
            tab.page.kind === 'terminals'
              ? waiting.size > 0
              : tab.page.kind === 'execution' && waiting.has(tab.page.id)
          const mark =
            marked === index
              ? 'before'
              : marked === ids.length && index === ids.length - 1
                ? 'after'
                : undefined
          return (
            <div
              key={tab.id}
              className="tab"
              data-selected={selected}
              data-dragging={dragging === tab.id ? true : undefined}
              data-drop={mark}
              onPointerDown={pinned ? undefined : (event) => press(event, tab.id)}
              onMouseDown={(event) => {
                // A middle button would otherwise start the browser's scrolling.
                if (event.button === 1) event.preventDefault()
              }}
              onAuxClick={(event) => {
                if (event.button !== 1 || pinned) return
                event.preventDefault()
                void requestClose(tab)
              }}
            >
              <button
                role="tab"
                className="tab-label"
                title={title}
                aria-selected={selected}
                onClick={() => dispatch({ type: 'activateTab', id: tab.id })}
                onKeyDown={(event) => {
                  if (!event.altKey || pinned) return
                  const step = event.key === 'ArrowLeft' ? -1 : event.key === 'ArrowRight' ? 1 : 0
                  if (step === 0) return
                  event.preventDefault()
                  dispatch({ type: 'moveTab', id: tab.id, to: index + step })
                }}
              >
                {title}
                {wanted && (
                  <span className="attention-dot" role="img" aria-label="Waiting for you" />
                )}
              </button>
              {!pinned && (
                <button
                  className="icon-button"
                  aria-label={`Close ${title}`}
                  onClick={() => void requestClose(tab)}
                >
                  <CloseIcon />
                </button>
              )}
            </div>
          )
        })}
      </div>
      {asking !== null && (
        <div
          className="tab-confirm"
          role="alertdialog"
          aria-label={`Close ${asking.title}?`}
          onKeyDown={(event) => {
            if (event.key === 'Escape') setAsking(null)
          }}
        >
          <span>{asking.warning}</span>
          <button className="secondary" autoFocus onClick={() => setAsking(null)}>
            Keep it open
          </button>
          <button
            className="primary"
            onClick={() => {
              dispatch({ type: 'closeTab', id: asking.id })
              setAsking(null)
            }}
          >
            Close {asking.title}
          </button>
        </div>
      )}
    </>
  )
}
