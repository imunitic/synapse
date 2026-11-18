// The Activity tab of the Changes sidebar, for a terminal session: what the harness in it was told
// and did, read from the session file it writes as it grows, every tool call with its result in
// full, and chosen by kind of action. It stays at the bottom while new actions come, unless the
// person has scrolled up.

import { useEffect, useMemo, useRef, useState } from 'react'
import { ActivityBody, KindChips } from '../components/ActivityView.tsx'
import { readSessionLog, samePath, type ActionKind } from '../domain/activity.ts'
import { conversationsOf, onConversationsChange } from '../state/conversations.ts'
import { baseName } from '../domain/changes.ts'

export function ActivityTab({
  session,
  kinds,
  onKinds,
  file,
  onFile,
  onShowChange,
}: {
  session: string
  // The kinds of action shown; none is all.
  kinds: readonly ActionKind[]
  onKinds: (kinds: ActionKind[]) => void
  // The file whose actions alone are shown, and choosing one or none.
  file: string | null
  onFile: (file: string | null) => void
  // A file the conversation changed is shown in the Changes tab.
  onShowChange: (path: string) => void
}) {
  const [, setTick] = useState(0)
  useEffect(() => onConversationsChange(() => setTick((n) => n + 1)), [])
  const followed = conversationsOf(session)
  const [chosen, setChosen] = useState<string | null>(null)
  const [expanded, setExpanded] = useState(false)
  const body = useRef<HTMLDivElement>(null)
  // Whether the person is at the bottom, which is where new actions show.
  const atBottom = useRef(true)
  const current = followed.find((f) => f.id === chosen) ?? followed.at(-1)
  const activity = useMemo(
    () =>
      current === undefined ? null : readSessionLog(current.harness, current.lines.join('\n')),
    // Every change to the lines makes a new list, which is what says they are not the ones
    // that were read.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [current?.id, current?.lines],
  )
  const shown = useMemo(() => new Set(kinds), [kinds])

  useEffect(() => {
    const element = body.current
    if (element !== null && atBottom.current) element.scrollTop = element.scrollHeight
  }, [activity, expanded, shown])

  if (current === undefined || activity === null) {
    return <p className="panel-empty">No harness conversation is followed in this session.</p>
  }
  return (
    <>
      <div className="activity-tab-head">
        {followed.length > 1 &&
          followed.map((f, i) => (
            <button
              key={f.id}
              className="chip"
              aria-pressed={f.id === current.id}
              onClick={() => setChosen(f.id)}
            >
              {f.harness} {i + 1}
            </button>
          ))}
        {file !== null && (
          <button
            className="chip chip-button"
            aria-label={`Show every file, not only ${baseName(file)}`}
            title={file}
            onClick={() => onFile(null)}
          >
            {baseName(file)} only ✕
          </button>
        )}
        <KindChips
          actions={activity.actions}
          kinds={shown}
          onKinds={(next) => onKinds([...next])}
        />
        <span className="activity-tab-actions">
          <button className="link" aria-pressed={expanded} onClick={() => setExpanded(!expanded)}>
            {expanded ? 'Collapse all' : 'Expand all'}
          </button>
        </span>
      </div>
      <div
        ref={body}
        className="activity-tab-body"
        aria-label="Activity"
        onScroll={(event) => {
          const e = event.currentTarget
          atBottom.current = e.scrollHeight - e.scrollTop - e.clientHeight < 24
        }}
      >
        <ActivityBody
          activity={activity}
          expanded={expanded}
          onShowChange={onShowChange}
          kinds={shown}
          file={file}
          onFile={(path) => onFile(file !== null && samePath(file, path) ? null : path)}
          empty={`Nothing has been said in this ${current.harness} session yet.`}
        />
      </div>
    </>
  )
}
