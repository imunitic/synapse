import { useEffect, useReducer, useRef } from 'react'
import { useConfig } from '../state/config.tsx'
import { transport } from '../transport/index.ts'
import { PageView } from './PageView.tsx'
import { ChangesSidebar } from './ChangesSidebar.tsx'
import { ChangesToggle } from './ChangesToggle.tsx'
import { OutlineSidebar } from './OutlineSidebar.tsx'
import { Rail } from './Rail.tsx'
import { SidePanel } from './SidePanel.tsx'
import { StatusBar } from './StatusBar.tsx'
import { TerminalsPage } from '../pages/TerminalsPage.tsx'
import { storedName, storeName } from '../domain/terminal-names.ts'
import { defaultBase } from '../domain/changes.ts'
import { keepBaseline } from '../state/change-baselines.ts'
import { isLiveRun, reduce, startState } from '../state/state.ts'
import { fileCount, useChanges, type ChangesSource } from '../state/useChanges.ts'
import { useCommits } from '../state/useCommits.ts'
import { clearReview } from '../state/reviews.ts'
import { useNoteReview } from '../state/note-reviews.ts'
import { useWaitingRuns } from '../state/useWaitingRuns.ts'
import { TabBar } from './TabBar.tsx'
import '../app/shell.css'

// A window this narrow, or narrower, has no room for the side panel beside a page.
const NARROW_PX = 1000

export function Shell() {
  const [state, dispatch] = useReducer(reduce, startState)
  useEffect(() => {
    if (typeof window.matchMedia !== 'function') return
    const narrow = window.matchMedia(`(max-width: ${NARROW_PX}px)`)
    const shut = () => {
      if (narrow.matches) dispatch({ type: 'setPanel', open: false })
    }
    shut()
    narrow.addEventListener('change', shut)
    return () => narrow.removeEventListener('change', shut)
  }, [])
  // The sessions the host held when the page began, such as after a reload, are attached to.
  useEffect(() => {
    let current = true
    transport
      .listTerminals()
      .then((sessions) => {
        if (!current) return
        dispatch({ type: 'adoptTerminals', sessions })
        // The names given to them before the page was reloaded.
        for (const session of sessions) {
          const name = storedName(session.session)
          if (name !== null) dispatch({ type: 'renameTerminal', id: session.session, name })
        }
      })
      .catch(() => undefined)
    return () => {
      current = false
    }
  }, [])
  // A session that leaves the state was closed, by its tab or with the page of the terminals:
  // the host ends it. Its view going away does not, since a view also goes away when its code is
  // swapped in development, and the session has to outlive that.
  const sessionIds = useRef<ReadonlySet<string>>(new Set())
  useEffect(() => {
    const now = new Set(state.terminals.map((t) => t.id))
    for (const id of sessionIds.current) {
      if (now.has(id)) continue
      transport.closeTerminal(id).catch(() => undefined)
      storeName(id, null)
      keepBaseline(id, null)
    }
    sessionIds.current = now
  }, [state.terminals])
  const { state: config } = useConfig()
  // The interactive runs that wait for a person, which the tabs and the terminals say.
  const waiting = useWaitingRuns(
    state.terminals.flatMap((t) =>
      isLiveRun(t) && t.executionId !== undefined ? [t.executionId] : [],
    ),
  )
  const active = state.tabs.find((tab) => tab.id === state.activeId)
  // The changes shown are those of the terminal session that is showing, or of the run whose page it
  // is.
  const activeSession = state.terminals.find((t) => t.id === state.activeTerminal)
  const changesSource: ChangesSource | null =
    active?.page.kind === 'terminals' && activeSession !== undefined
      ? {
          kind: 'session',
          session: activeSession.id,
          base: state.changesBases[activeSession.id] ?? defaultBase(activeSession),
        }
      : active?.page.kind === 'execution'
        ? { kind: 'run', executionId: active.page.id }
        : null
  const changes = useChanges(changesSource, state.changesOpen)
  // A terminal session also has the Git tab: the commits of the branch its harness is on.
  const gitSession =
    active?.page.kind === 'terminals' && activeSession !== undefined ? activeSession.id : null
  const changesTab = gitSession === null ? 'changes' : (state.changesTabs[gitSession] ?? 'changes')
  const gitCommit = gitSession === null ? null : (state.gitCommits[gitSession] ?? null)
  const commits = useCommits(gitSession, state.changesOpen && changesTab === 'git', gitCommit)
  // On a note page the sidebar is the note's outline, with its review comments.
  const notePath = active?.page.kind === 'note' ? active.page.path : null
  const noteComments = useNoteReview(notePath)
  const missingWorkDir = config.status === 'ready' && config.config.workDir === null

  return (
    <div className="shell">
      <div className="shell-body">
        <Rail state={state} dispatch={dispatch} />
        {state.panelOpen && <SidePanel state={state} dispatch={dispatch} />}
        <main className="main">
          {notePath === null ? (
            <ChangesToggle
              open={state.changesOpen}
              count={fileCount(changes.state)}
              onToggle={() => dispatch({ type: 'toggleChanges' })}
            />
          ) : (
            <ChangesToggle
              open={state.changesOpen}
              count={noteComments.length}
              onToggle={() => dispatch({ type: 'toggleChanges' })}
              label="Show or hide the outline"
              counted={noteComments.length === 1 ? 'comment' : 'comments'}
            />
          )}
          <TabBar state={state} dispatch={dispatch} waiting={waiting} />
          {missingWorkDir && (
            <div className="banner" role="status">
              <span>
                There is no home directory to keep Synapse's working files in, so runs leave no
                record. Set a work directory.
              </span>
              <button
                className="banner-button"
                onClick={() =>
                  dispatch({ type: 'openPage', page: { kind: 'settings', section: 'general' } })
                }
              >
                Set work directory
              </button>
            </div>
          )}
          <div className="content" role="tabpanel">
            {/* A session goes on while another tab shows, so the terminals stay mounted. */}
            {state.terminals.length > 0 && (
              <TerminalsPage
                sessions={state.terminals}
                activeId={state.activeTerminal}
                visible={active?.page.kind === 'terminals'}
                waiting={waiting}
                onSelect={(id) => dispatch({ type: 'selectTerminal', id })}
                onClose={(id) => {
                  // Its review goes with it.
                  clearReview(id)
                  dispatch({ type: 'closeTerminal', id })
                }}
                onEnded={(id) => dispatch({ type: 'terminalEnded', id })}
                onClaimed={(id) => dispatch({ type: 'terminalClaimed', id })}
                onRename={(id, name) => {
                  storeName(id, name)
                  dispatch({ type: 'renameTerminal', id, name })
                }}
                onMove={(id, to) => dispatch({ type: 'moveTerminal', id, to })}
                onRun={(id, executionId) => dispatch({ type: 'terminalRun', id, executionId })}
                onNew={() =>
                  dispatch({
                    type: 'openTerminal',
                    kind: 'Shell',
                    cwd: '',
                    id: Math.random().toString(36).slice(2, 8),
                  })
                }
              />
            )}
            {active !== undefined && active.page.kind !== 'terminals' && (
              <PageView
                key={active.id}
                page={active.page}
                onOpen={(page) => dispatch({ type: 'openPage', page })}
                terminals={state.terminals}
                onSelectTerminal={(id) => {
                  dispatch({ type: 'openPage', page: { kind: 'terminals' } })
                  dispatch({ type: 'selectTerminal', id })
                }}
                onShowChanges={(visit, path) =>
                  dispatch({ type: 'showChanges', visit, ...(path === undefined ? {} : { path }) })
                }
                onStartTask={(kind, cwd, task) =>
                  dispatch({
                    type: 'openTerminal',
                    kind,
                    cwd,
                    task,
                    id: Math.random().toString(36).slice(2, 8),
                  })
                }
                onStartTerminal={(kind) =>
                  dispatch({
                    type: 'openTerminal',
                    kind,
                    cwd: config.status === 'ready' ? (config.config.terminalFolder ?? '') : '',
                    id: Math.random().toString(36).slice(2, 8),
                  })
                }
                onStartIn={(kind, cwd, resume) =>
                  dispatch({
                    type: 'openTerminal',
                    kind,
                    cwd,
                    ...(resume === undefined ? {} : { resume }),
                    id: Math.random().toString(36).slice(2, 8),
                  })
                }
                onStartRun={(pipeline, input, folder) =>
                  dispatch({
                    type: 'openTerminal',
                    kind: 'Pipeline',
                    cwd: folder,
                    title: pipeline,
                    pipeline,
                    ...(input === undefined ? {} : { input }),
                    id: Math.random().toString(36).slice(2, 8),
                  })
                }
                onRunCommand={(command, title) =>
                  dispatch({
                    type: 'openTerminal',
                    kind: 'Shell',
                    cwd: config.status === 'ready' ? (config.config.terminalFolder ?? '') : '',
                    command,
                    title,
                    id: Math.random().toString(36).slice(2, 8),
                  })
                }
                onCreated={(page) =>
                  dispatch({ type: 'definitionCreated', closeId: active.id, page })
                }
                onChanged={() => dispatch({ type: 'definitionsChanged' })}
                onCancel={() => dispatch({ type: 'closeTab', id: active.id })}
              />
            )}
          </div>
        </main>
        {state.changesOpen && notePath !== null && <OutlineSidebar path={notePath} />}
        {state.changesOpen && notePath === null && (
          <ChangesSidebar
            state={changes.state}
            onRefresh={changes.refresh}
            focusVisit={state.changesVisit}
            focusFile={state.changesFile}
            onBase={(base) =>
              activeSession !== undefined &&
              dispatch({ type: 'setChangesBase', session: activeSession.id, base })
            }
            reviewSession={gitSession}
            activity={
              gitSession === null
                ? null
                : {
                    kinds: state.activityKinds[gitSession] ?? [],
                    onKinds: (kinds) =>
                      dispatch({ type: 'setActivityKinds', session: gitSession, kinds }),
                    file: state.activityFiles[gitSession] ?? null,
                    onFile: (file) =>
                      dispatch({ type: 'setActivityFile', session: gitSession, file }),
                    // A file the conversation changed is shown in the Changes tab, compared with
                    // where the session started: what was committed since is in that comparison
                    // and not in the one with the last commit.
                    onShowChange: (path) => {
                      dispatch({ type: 'setChangesBase', session: gitSession, base: 'start' })
                      dispatch({ type: 'setChangesTab', session: gitSession, tab: 'changes' })
                      dispatch({ type: 'showChanges', visit: null, path })
                    },
                  }
            }
            git={
              gitSession === null
                ? null
                : {
                    tab: changesTab,
                    onTab: (tab) => dispatch({ type: 'setChangesTab', session: gitSession, tab }),
                    list: commits.list,
                    view: commits.view,
                    commit: gitCommit,
                    readFile: commits.readFile,
                    onCommit: (commit) =>
                      dispatch({ type: 'setGitCommit', session: gitSession, commit }),
                    onLoadMore: commits.loadMore,
                    onRefresh: commits.refresh,
                  }
            }
          />
        )}
      </div>
      <StatusBar />
    </div>
  )
}
