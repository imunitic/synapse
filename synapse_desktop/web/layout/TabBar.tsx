import { useEffect, useRef, useState, type Dispatch, type DragEvent } from 'react'
import { CloseIcon } from '../components/icons.tsx'
import { listExecutions } from '../domain/executions.ts'
import { closeWarning, firstMovableIndex, indexAfterMove, insertionPoint } from '../domain/tabs.ts'
import { pageTitle, type Action, type ShellState, type Tab } from '../state/state.ts'
import { transport } from '../transport/index.ts'

// What a close that has to ask is asking about.
interface Asking {
  id: string
  title: string
  warning: string
}

// The tabs of the open pages. They are put in another order by dragging them, or with Alt and
// the arrow keys; the Home tab is first and stays there. A tab is closed with its button or a
// middle click, which asks first when that would cut something short.
export function TabBar({ state, dispatch }: { state: ShellState; dispatch: Dispatch<Action> }) {
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
    const runs =
      tab.page.kind === 'execution' ? await listExecutions(transport).catch(() => []) : []
    const warning = closeWarning(tab.page, state.terminals, runs)
    if (warning === null) {
      dispatch({ type: 'closeTab', id: tab.id })
    } else {
      setAsking({ id: tab.id, title: pageTitle(tab.page), warning })
    }
  }

  function over(event: DragEvent<HTMLElement>, index: number) {
    if (dragging === null) return
    event.preventDefault()
    const box = event.currentTarget.getBoundingClientRect()
    const point = insertionPoint(index, (event.clientX - box.left) / box.width)
    setDrop(Math.max(point, firstMovableIndex(ids)))
  }

  function finish() {
    setDragging(null)
    setDrop(null)
  }

  function release(event: DragEvent<HTMLElement>) {
    event.preventDefault()
    const from = dragging === null ? -1 : ids.indexOf(dragging)
    if (dragging !== null && drop !== null && from !== -1) {
      dispatch({ type: 'moveTab', id: dragging, to: indexAfterMove(from, drop) })
    }
    finish()
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
        onDragOver={(event) => {
          // The space after the last tab.
          if (event.target === event.currentTarget && dragging !== null) {
            event.preventDefault()
            setDrop(ids.length)
          }
        }}
        onDrop={release}
        onWheel={(event) => {
          // The wheel turns up and down, and the bar goes sideways.
          if (Math.abs(event.deltaY) > Math.abs(event.deltaX)) {
            event.currentTarget.scrollLeft += event.deltaY
          }
        }}
      >
        {state.tabs.map((tab, index) => {
          const selected = tab.id === state.activeId
          const pinned = tab.id === 'home'
          const title = pageTitle(tab.page)
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
              draggable={!pinned}
              onDragStart={(event) => {
                event.dataTransfer.setData('text/plain', tab.id)
                event.dataTransfer.effectAllowed = 'move'
                setDragging(tab.id)
              }}
              onDragOver={(event) => over(event, index)}
              onDrop={release}
              onDragEnd={finish}
              onMouseDown={(event) => {
                // A middle button would otherwise start the browser's scrolling.
                if (event.button === 1) event.preventDefault()
              }}
              onAuxClick={(event) => {
                if (event.button !== 1) return
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
              </button>
              <button
                className="icon-button"
                aria-label={`Close ${title}`}
                onClick={() => void requestClose(tab)}
              >
                <CloseIcon />
              </button>
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
