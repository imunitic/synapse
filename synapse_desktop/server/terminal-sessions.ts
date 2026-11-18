// The terminal sessions of the host. A session is held here and not by a connection: a client that
// is gone leaves it running, and one that attaches later gets the screen as the program drew it and
// then what the program prints. A session ends when its program exits and its tab is closed, or
// when no client has been attached to it for DETACHED_TTL_MS.

import { randomBytes } from 'node:crypto'
import { rm } from 'node:fs/promises'
import { join, sep } from 'node:path'
import serializePackage from '@xterm/addon-serialize'
import headlessPackage from '@xterm/headless'
import type { TerminalHostStream, TerminalInfo, TerminalStartParams } from '../shared/terminal.ts'
import { HostError } from '../shared/dispatch.ts'
import { prepare, type Pty, type TerminalDeps } from './terminal.ts'
import { watchTranscripts, type Watcher } from './transcripts.ts'

// A session with no client attached for this long is ended. A fixed value.
export const DETACHED_TTL_MS = 12 * 60 * 60 * 1000

// What the screen keeps above what shows, which a client that attaches is given.
const SCROLLBACK_LINES = 100

// What of a conversation is kept to give a client that attaches again.
const MAX_TRANSCRIPT_LINES = 5000

interface Headless {
  write(data: string, done?: () => void): void
  resize(cols: number, rows: number): void
  loadAddon(addon: unknown): void
  dispose(): void
}

interface Serializer {
  serialize(options: { scrollback: number }): string
}

const { Terminal: HeadlessTerminal } = headlessPackage as unknown as {
  Terminal: new (options: {
    cols: number
    rows: number
    scrollback: number
    allowProposedApi: boolean
  }) => Headless
}
const { SerializeAddon } = serializePackage as unknown as { SerializeAddon: new () => Serializer }

// Where a session's output goes: one for each connection that is attached to it.
export interface Sink {
  send(session: string, message: TerminalHostStream): void
}

export interface SessionsDeps extends TerminalDeps {
  // Runs `action` after `ms` and returns what cancels it. The clock of the 12 hours, injected so
  // that the tests do not wait for it.
  schedule?: (action: () => void, ms: number) => () => void
}

interface Attached {
  // Output that arrives while the snapshot is being made waits here, so that it follows it.
  waiting: boolean
  buffer: TerminalHostStream[]
}

interface Session {
  info: Omit<TerminalInfo, 'exited'>
  owner: string
  pty: Pty
  screen: Headless
  serializer: Serializer
  sinks: Map<Sink, Attached>
  exited: number | null
  watcher: Watcher
  sessionsDir: string
  // What the conversations followed in it said, for a client that attaches later.
  sources: Map<string, TerminalHostStream & { type: 'transcript-source' }>
  lines: Map<string, string[]>
  cancelExpiry: (() => void) | null
}

const defaultSchedule = (action: () => void, ms: number): (() => void) => {
  const timer = setTimeout(action, ms)
  timer.unref()
  return () => clearTimeout(timer)
}

export interface Sessions {
  start(params: TerminalStartParams, owner: string, sink: Sink): Promise<TerminalInfo>
  attach(id: string, owner: string, sink: Sink, size: { cols: number; rows: number }): TerminalInfo
  // Ends what a connection had attached, without ending the sessions.
  detachAll(sink: Sink): void
  input(id: string, owner: string, sink: Sink, data: string): void
  resize(id: string, owner: string, sink: Sink, cols: number, rows: number): void
  // Ends a session and its program.
  close(id: string, owner: string): void
  list(owner: string): TerminalInfo[]
}

export function createSessions(deps: SessionsDeps): Sessions {
  const schedule = deps.schedule ?? defaultSchedule
  const sessions = new Map<string, Session>()
  // The sessions being started, so that two starts of one id do not both go on.
  const starting = new Set<string>()

  const infoOf = (session: Session): TerminalInfo => ({ ...session.info, exited: session.exited })

  function owned(id: string, owner: string): Session {
    const session = sessions.get(id)
    if (session === undefined) throw new HostError('not_found', `there is no session ${id}`)
    // A session belongs to the user who started it, and only that user can attach.
    if (session.owner !== owner) {
      throw new HostError('forbidden', 'the session belongs to another user')
    }
    return session
  }

  function destroy(session: Session): void {
    session.cancelExpiry?.()
    session.cancelExpiry = null
    if (session.exited === null) session.pty.kill()
    session.watcher.stop()
    session.screen.dispose()
    sessions.delete(session.info.session)
    // The folder is this session's own, inside the folder of the terminals.
    if (session.sessionsDir.startsWith(deps.sessionsRoot + sep)) {
      void rm(session.sessionsDir, { recursive: true, force: true })
    }
  }

  function expireWhenUnattended(session: Session): void {
    if (session.sinks.size > 0 || session.cancelExpiry !== null) return
    session.cancelExpiry = schedule(() => destroy(session), DETACHED_TTL_MS)
  }

  function deliver(session: Session, message: TerminalHostStream): void {
    for (const [sink, attached] of session.sinks) {
      if (attached.waiting) attached.buffer.push(message)
      else sink.send(session.info.session, message)
    }
  }

  const live = () => [...sessions.values()].filter((s) => s.exited === null).length

  return {
    async start(params, owner, sink) {
      if (sessions.has(params.session) || starting.has(params.session)) {
        throw new HostError('conflict', 'the session has started already')
      }
      if (live() + starting.size >= deps.maxTerminals) {
        throw new HostError('conflict', 'too many terminals are open')
      }
      starting.add(params.session)
      // The registrations of the runs in this terminal.
      const sessionsDir = join(deps.sessionsRoot, randomBytes(6).toString('hex'))
      let prepared
      try {
        prepared = await prepare(params, deps, sessionsDir)
      } finally {
        starting.delete(params.session)
      }
      const screen = new HeadlessTerminal({
        cols: params.cols,
        rows: params.rows,
        scrollback: SCROLLBACK_LINES,
        allowProposedApi: true,
      })
      const serializer = new SerializeAddon()
      screen.loadAddon(serializer)
      const session: Session = {
        info: {
          session: params.session,
          title: params.title,
          kind: params.kind,
          cwd: prepared.cwd,
          ...(params.task === undefined ? {} : { task: params.task }),
          ...(params.pipeline === undefined ? {} : { pipeline: params.pipeline }),
          ...(prepared.executionId === undefined ? {} : { executionId: prepared.executionId }),
          loaded: prepared.loaded,
          note: prepared.note,
        },
        owner,
        pty: prepared.pty,
        screen,
        serializer,
        sinks: new Map([[sink, { waiting: false, buffer: [] }]]),
        exited: null,
        watcher: undefined as unknown as Watcher,
        sessionsDir,
        sources: new Map(),
        lines: new Map(),
        cancelExpiry: null,
      }
      sessions.set(params.session, session)
      prepared.pty.onData((data) => {
        screen.write(data)
        deliver(session, { type: 'output', data })
      })
      prepared.pty.onExit(({ exitCode }) => {
        session.exited = exitCode
        session.watcher.stop()
        deliver(session, { type: 'exit', code: exitCode })
        if (session.sinks.size === 0) expireWhenUnattended(session)
      })
      session.watcher = (deps.watch ?? watchTranscripts)({
        dir: sessionsDir,
        home: deps.environment.home,
        events: {
          onSource: (source) => {
            const message = { type: 'transcript-source', ...source } as const
            session.sources.set(source.id, message)
            deliver(session, message)
          },
          onLines: (id, lines) => {
            const kept = [...(session.lines.get(id) ?? []), ...lines]
            session.lines.set(id, kept.slice(-MAX_TRANSCRIPT_LINES))
            deliver(session, { type: 'transcript', id, lines })
          },
        },
      })
      prepared.follow?.(session.watcher)
      return infoOf(session)
    },

    attach(id, owner, sink, size) {
      const session = owned(id, owner)
      session.cancelExpiry?.()
      session.cancelExpiry = null
      if (session.exited === null) {
        session.pty.resize(size.cols, size.rows)
        session.screen.resize(size.cols, size.rows)
      }
      const attached: Attached = { waiting: true, buffer: [] }
      session.sinks.set(sink, attached)
      // A write that is done is one after which the screen has all that was printed before it, and
      // none of what is printed after: the snapshot is exactly the line between the two.
      session.screen.write('', () => {
        if (session.sinks.get(sink) !== attached) return
        sink.send(id, {
          type: 'snapshot',
          data: session.serializer.serialize({ scrollback: SCROLLBACK_LINES }),
        })
        for (const source of session.sources.values()) sink.send(id, source)
        for (const [lineId, lines] of session.lines) {
          sink.send(id, { type: 'transcript', id: lineId, lines })
        }
        for (const message of attached.buffer.splice(0)) sink.send(id, message)
        attached.waiting = false
        if (session.exited !== null) sink.send(id, { type: 'exit', code: session.exited })
      })
      return infoOf(session)
    },

    detachAll(sink) {
      for (const session of sessions.values()) {
        if (session.sinks.delete(sink)) expireWhenUnattended(session)
      }
    },

    input(id, owner, sink, data) {
      const session = owned(id, owner)
      if (session.sinks.has(sink) && session.exited === null) session.pty.write(data)
    },

    resize(id, owner, sink, cols, rows) {
      const session = owned(id, owner)
      if (!session.sinks.has(sink) || session.exited !== null) return
      session.pty.resize(cols, rows)
      session.screen.resize(cols, rows)
    },

    close(id, owner) {
      destroy(owned(id, owner))
    },

    list(owner) {
      return [...sessions.values()].filter((s) => s.owner === owner).map(infoOf)
    },
  }
}
