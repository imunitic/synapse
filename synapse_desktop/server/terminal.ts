// A terminal is a harness in a pty, reached over one WebSocket: the page says
// which harness and where, types into it, and gets what it prints. The
// handshake has to pass the same guards as any request, since a terminal runs
// programs.

import type { IncomingMessage, Server } from 'node:http'
import { stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { isAbsolute, join } from 'node:path'
import * as nodePty from '@lydell/node-pty'
import { WebSocketServer, type WebSocket } from 'ws'
import { TERMINAL_PATH, TOKEN_HEADER } from '../shared/constants.ts'
import { clientMessageSchema, type ServerMessage } from '../shared/terminal.ts'
import type { TerminalKind } from '../shared/transport.ts'
import { cliEnvironment } from './cli.ts'
import { loadConfig } from './config-store.ts'
import { checkUpgrade, type Policy } from './guards.ts'
import { planSession, planShell, type SessionPlan } from './inject.ts'
import type { Environment } from './roots.ts'

export interface Pty {
  onData(listener: (data: string) => void): void
  onExit(listener: (exit: { exitCode: number }) => void): void
  write(data: string): void
  resize(cols: number, rows: number): void
  kill(): void
}

export type SpawnPty = (
  file: string,
  args: string[],
  options: { cwd: string; env: Record<string, string>; cols: number; rows: number },
) => Pty

export const spawnPty: SpawnPty = (file, args, options) =>
  nodePty.spawn(file, args, { name: 'xterm-256color', ...options })

export interface TerminalDeps {
  policy: Policy
  environment: Environment
  configFile: string
  spawn: SpawnPty
  // How the harness is started for a session.
  plan: (kind: TerminalKind) => Promise<SessionPlan>
  maxTerminals: number
}

// Where the app keeps what it makes for the harnesses it injects Synapse into.
export function injectedDir(environment: Environment): string {
  const base = environment.env.XDG_DATA_HOME
    ? environment.env.XDG_DATA_HOME
    : join(environment.home, '.local', 'share')
  return join(base, 'synapse-desktop', 'injected')
}

export function defaultPlan(environment: Environment): TerminalDeps['plan'] {
  return (kind) => {
    const deps = {
      env: environment.env,
      home: environment.home || homedir(),
      dataDir: injectedDir(environment),
    }
    return kind === 'Shell' ? planShell(deps) : planSession(kind, deps)
  }
}

function header(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name]
  return Array.isArray(value) ? value[0] : value
}

function send(ws: WebSocket, message: ServerMessage): void {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(message))
}

async function isDirectory(path: string): Promise<boolean> {
  return (await stat(path).catch(() => null))?.isDirectory() ?? false
}

// What a harness sets for the programs it starts, which tells one of them that it
// is inside another session, and how to reach that session. A terminal of the app
// is a session of its own, so it does not have them.
const OF_ANOTHER_SESSION = [
  'CLAUDECODE',
  'CLAUDE_CODE_CHILD_SESSION',
  'CLAUDE_CODE_SESSION_ID',
  'CLAUDE_CODE_SESSION_ATTENDED',
  'CLAUDE_CODE_MESSAGING_SOCKET',
  'CLAUDE_CODE_MESSAGING_TOKEN',
  'CLAUDE_CODE_ENTRYPOINT',
  'CLAUDE_CODE_EXECPATH',
  'CLAUDE_PID',
]

// Only strings: the environment of a process has nothing else.
function strings(env: Record<string, string | undefined>): Record<string, string> {
  return Object.fromEntries(
    Object.entries(env).filter((entry): entry is [string, string] => entry[1] !== undefined),
  )
}

async function start(
  ws: WebSocket,
  message: Extract<ReturnType<typeof clientMessageSchema.parse>, { type: 'start' }>,
  deps: TerminalDeps,
): Promise<Pty | null> {
  const cwd = message.cwd ?? deps.environment.home
  if (!isAbsolute(cwd) || !(await isDirectory(cwd))) {
    send(ws, { type: 'error', message: `${cwd} is not a folder` })
    return null
  }
  const plan = await deps.plan(message.kind)
  const config = await loadConfig(deps.configFile)
  const env = {
    ...Object.fromEntries(
      Object.entries(strings(cliEnvironment(deps.environment.env, config))).filter(
        ([name]) => !OF_ANOTHER_SESSION.includes(name),
      ),
    ),
    ...plan.env,
    TERM: 'xterm-256color',
  }
  let pty: Pty
  try {
    pty = deps.spawn(plan.command, plan.args, { cwd, env, cols: message.cols, rows: message.rows })
  } catch (error) {
    send(ws, { type: 'error', message: `${plan.command} could not be started: ${String(error)}` })
    return null
  }
  send(ws, { type: 'started', loaded: plan.loaded, note: plan.note })
  return pty
}

function connection(
  ws: WebSocket,
  deps: TerminalDeps,
  count: () => number,
  bump: (by: number) => void,
) {
  let pty: Pty | null = null
  let starting = false
  let counted = false

  ws.on('message', (raw) => {
    void (async () => {
      let message
      try {
        message = clientMessageSchema.parse(JSON.parse(String(raw)))
      } catch {
        send(ws, { type: 'error', message: 'the message is not one a terminal takes' })
        ws.close()
        return
      }
      if (message.type === 'start') {
        if (pty !== null || starting) {
          send(ws, { type: 'error', message: 'the session has started already' })
          return
        }
        if (count() >= deps.maxTerminals) {
          send(ws, { type: 'error', message: 'too many terminals are open' })
          ws.close()
          return
        }
        starting = true
        const started = await start(ws, message, deps).catch((error: unknown) => {
          send(ws, { type: 'error', message: String(error) })
          return null
        })
        starting = false
        if (started === null) {
          ws.close()
          return
        }
        if (ws.readyState !== ws.OPEN) {
          started.kill()
          return
        }
        pty = started
        counted = true
        bump(1)
        pty.onData((data) => send(ws, { type: 'output', data }))
        pty.onExit(({ exitCode }) => {
          send(ws, { type: 'exit', code: exitCode })
          ws.close()
        })
      } else if (pty !== null && message.type === 'input') {
        pty.write(message.data)
      } else if (pty !== null && message.type === 'resize') {
        pty.resize(message.cols, message.rows)
      }
    })()
  })

  ws.on('close', () => {
    pty?.kill()
    if (counted) bump(-1)
  })
}

// Answers the WebSocket handshakes of terminals on `server`.
export function attachTerminals(server: Server, deps: TerminalDeps): void {
  const sockets = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024 })
  let open = 0
  server.on('upgrade', (req, socket, head) => {
    if (req.url !== TERMINAL_PATH) {
      socket.destroy()
      return
    }
    const refusal = checkUpgrade(
      {
        host: header(req, 'host'),
        origin: header(req, 'origin'),
        token: header(req, TOKEN_HEADER),
      },
      deps.policy,
    )
    if (refusal !== null) {
      socket.write(`HTTP/1.1 ${refusal.status} Refused\r\nConnection: close\r\n\r\n`)
      socket.destroy()
      return
    }
    sockets.handleUpgrade(req, socket, head, (ws) =>
      connection(
        ws,
        deps,
        () => open,
        (by) => {
          open += by
        },
      ),
    )
  })
}
