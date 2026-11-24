// What the host tells a client that subscribed to a topic: that something under a place changed, and
// the events of a run as they are written. A subscription is made when the client asks and ended
// with its connection.

import { watch as fsWatch, type FSWatcher } from 'node:fs'
import { join } from 'node:path'
import type { Cursor, Topic } from '../shared/protocol.ts'
import { askRun, NotListening, socketPath } from './run-socket.ts'
import { loadConfig } from './config-store.ts'
import { existingDirs, definitionDirs } from './roots.ts'
import { vaultDirOf } from './note-agent.ts'
import type { Context } from './calls.ts'

type Push = (data: unknown, cursor?: Cursor) => void

export interface TopicOptions {
  context: Context
  // How long changes are gathered before the client is told.
  debounceMs?: number
  // How often the places are looked up again, since a work directory can be set or a vault chosen
  // while the client is subscribed.
  relookMs?: number
  // How often a run is asked for its new events.
  pollMs?: number
  watch?: typeof fsWatch
}

// Folders that change without the notes or the runs changing.
function ignored(name: string | null): boolean {
  if (name === null) return false
  return name.split(/[\\/]/).some((part) => part === '.git' || part === '.obsidian')
}

async function placeDirs(place: string, context: Context): Promise<string[]> {
  const config = await loadConfig(context.configFile, context.environment)
  switch (place) {
    case 'work':
      return existingDirs(config.workDir === null ? [] : [join(config.workDir, 'pipelines')])
    case 'definitions':
      return existingDirs(definitionDirs(config, context.environment))
    case 'vault': {
      const settings = await context.runCli({
        binary: 'synapse',
        args: ['config', 'list', '--format', 'json'],
        config,
      })
      const vault = vaultDirOf(settings.stdout)
      return vault === null ? [] : existingDirs([vault])
    }
    default:
      return []
  }
}

export function createTopics(options: TopicOptions) {
  const debounceMs = options.debounceMs ?? 250
  const relookMs = options.relookMs ?? 10_000
  const pollMs = options.pollMs ?? 1000
  const watch = options.watch ?? fsWatch
  const { context } = options

  function files(place: string, push: Push): () => void {
    let watchers: FSWatcher[] = []
    let key: string | null = null
    let timer: NodeJS.Timeout | undefined
    let stopped = false

    const changed = () => {
      clearTimeout(timer)
      timer = setTimeout(() => {
        if (!stopped) push({})
      }, debounceMs)
    }

    const look = async () => {
      let dirs: string[]
      try {
        dirs = await placeDirs(place, context)
      } catch {
        return
      }
      const next = dirs.join('\0')
      if (stopped || next === key) return
      const first = key === null
      key = next
      for (const watcher of watchers) watcher.close()
      watchers = []
      for (const dir of dirs) {
        try {
          const watcher = watch(dir, { recursive: true }, (_event, name) => {
            if (!ignored(name)) changed()
          })
          watcher.on('error', () => undefined)
          watchers.push(watcher)
        } catch {
          // A folder that cannot be watched is looked up again with the others.
          key = null
        }
      }
      // What a client shows may be from before the folder was there.
      if (!first) changed()
    }

    void look()
    const again = setInterval(() => void look(), relookMs)
    return () => {
      stopped = true
      clearInterval(again)
      clearTimeout(timer)
      for (const watcher of watchers) watcher.close()
    }
  }

  // The events of a run, each with its own sequence number as its cursor.
  function run(id: string, after: Cursor | undefined, push: Push): () => void {
    let cursor = after
    let stopped = false
    let busy = false
    const poll = async () => {
      if (busy || stopped) return
      busy = true
      try {
        const { workDir } = await loadConfig(context.configFile, context.environment)
        if (workDir === null) return
        const path = socketPath(join(workDir, 'pipelines'), id, process.platform)
        const answer = await askRun(path, {
          command: 'events',
          ...(cursor === undefined ? {} : { after: cursor }),
        })
        if (!answer.ok) return
        const result = answer.result as unknown
        const list = Array.isArray(result)
          ? result
          : Array.isArray((result as { events?: unknown })?.events)
            ? (result as { events: unknown[] }).events
            : []
        for (const event of list) {
          const sequence = (event as { sequence?: unknown }).sequence
          if (typeof sequence !== 'number' || stopped) continue
          push(event, sequence)
          cursor = Math.max(cursor ?? -1, sequence)
        }
      } catch (error) {
        // A run that is not listening is over, or has not started: it is asked again.
        if (!(error instanceof NotListening)) return
      } finally {
        busy = false
      }
    }
    void poll()
    const timer = setInterval(() => void poll(), pollMs)
    return () => {
      stopped = true
      clearInterval(timer)
    }
  }

  return function subscribe(topic: Topic, after: Cursor | undefined, push: Push): () => void {
    if (topic.startsWith('note-run.')) {
      return context.noteRuns.subscribe(topic.slice('note-run.'.length), after, push)
    }
    if (topic.startsWith('files.')) return files(topic.slice('files.'.length), push)
    return run(topic.slice('run.'.length), after, push)
  }
}
