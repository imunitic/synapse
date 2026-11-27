import { useEffect, useRef, useState, type Dispatch } from 'react'
import { CloseIcon } from '../components/icons.tsx'
import { listExecutions } from '../domain/executions.ts'
import { closeWarning, firstMovableIndex } from '../domain/tabs.ts'
import { tabTitle, type Action, type ShellState, type Tab } from '../state/state.ts'
import { useRunNames } from '../state/useRunNames.ts'
import { transport } from '../transport/index.ts'
import { useTabDrag } from './use-tab-drag.ts'

// The page that is always there, first, and is not closed.
const HOME = 'home'

// What a close that has to ask is asking about.
interface Asking {
  id: string
  title: string
  warning: string
}

// The tabs of the open pages. They are put in another order by dragging them, or with Alt and
// the arrow keys (dragging is `useTabDrag`); the Home tab is first and stays there. A tab is closed
// with its button or a middle click, which asks first when that would cut something short.
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
  const runNames = useRunNames(
    state.tabs.flatMap((t) => (t.page.kind === 'execution' ? [t.page.id] : [])),
  )
  const [asking, setAsking] = useState<Asking | null>(null)
  const bar = useRef<HTMLDivElement>(null)
  const { dragging, press, markOf } = useTabDrag({
    row: bar,
    tabSelector: ':scope > .tab',
    ids,
    first: firstMovableIndex(ids),
    onMove: (id, to) => dispatch({ type: 'moveTab', id, to }),
  })

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
      setAsking({ id: tab.id, title: tabTitle(tab.page, state.terminals, runNames), warning })
    }
  }

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
          const title = tabTitle(tab.page, state.terminals, runNames)
          // A tab shows a person is wanted in what it holds: the terminals, or the run.
          const wanted =
            tab.page.kind === 'terminals'
              ? waiting.size > 0
              : tab.page.kind === 'execution' && waiting.has(tab.page.id)
          return (
            <div
              key={tab.id}
              className="tab"
              data-selected={selected}
              data-dragging={dragging === tab.id ? true : undefined}
              data-drop={markOf(index)}
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
