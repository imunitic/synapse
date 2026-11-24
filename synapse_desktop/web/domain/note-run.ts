// What the page shows of a run that is going on: how long it has run, and what the agent is doing
// now, read from the stream-json lines a Claude run publishes.

import { readActivity, type Activity } from './activity.ts'

const pad = (n: number) => String(n).padStart(2, '0')

// How long a run has gone on: `0:42` and `12:05` under an hour, `1:02:03` from an hour.
export function formatElapsed(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const seconds = total % 60
  return hours > 0 ? `${hours}:${pad(minutes)}:${pad(seconds)}` : `${minutes}:${pad(seconds)}`
}

// The lines that are the messages of a Claude transcript, as one text that `readActivity` reads.
// The `system` and `result` lines and anything that is not JSON are left out.
export function claudeLines(lines: readonly string[]): string {
  return lines
    .filter((line) => {
      try {
        const event: unknown = JSON.parse(line)
        const type =
          typeof event === 'object' && event !== null ? (event as { type?: unknown }).type : null
        return type === 'assistant' || type === 'user'
      } catch {
        return false
      }
    })
    .join('\n')
}

export function activityOfRun(lines: readonly string[]): Activity {
  return readActivity(claudeLines(lines))
}

const COMMAND_LIMIT = 60

function fileName(path: string): string {
  return (
    path
      .split('/')
      .filter((part) => part !== '')
      .pop() ?? path
  )
}

// The newest action as a sentence, or null when there are none.
export function latestAction(activity: Activity): string | null {
  const action = activity.actions.at(-1)
  if (action === undefined) return null
  const target = action.target
  switch (action.kind) {
    case 'read':
      return target === null ? 'Reading' : `Reading ${fileName(target)}`
    case 'write':
      return target === null ? 'Writing' : `Writing ${fileName(target)}`
    case 'edit':
      return target === null ? 'Editing' : `Editing ${fileName(target)}`
    case 'command': {
      if (target === null) return 'Running a command'
      const shown = target.length > COMMAND_LIMIT ? `${target.slice(0, COMMAND_LIMIT)}…` : target
      return `Running ${shown}`
    }
    case 'search':
      return target === null ? 'Searching' : `Searching ${target}`
    case 'message':
      return 'Writing a reply'
    case 'thinking':
      return 'Thinking'
    default:
      return 'Working'
  }
}
