// What starting a terminal takes: where it runs, the program the plan gives and the arguments each
// harness is started with. The sessions that hold what it starts are in terminal-sessions.ts.

import { randomBytes, randomUUID } from 'node:crypto'
import { mkdir, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { isAbsolute, join } from 'node:path'
import * as nodePty from '@lydell/node-pty'
import { HostError } from '../shared/dispatch.ts'
import type { TerminalStartParams } from '../shared/terminal.ts'
import type { TerminalKind } from '../shared/transport.ts'
import { cliEnvironment } from './cli.ts'
import { harnessEnvironment, readLoginEnvironment } from './doctor.ts'
import { expandHome } from './home.ts'
import { taskArgs } from './tasks.ts'
import { loadConfig } from './config-store.ts'
import { planSession, planShell, type SessionPlan } from './inject.ts'
import type { Environment } from './roots.ts'
import type { Watcher, watchTranscripts } from './transcripts.ts'
import { isDirectory } from './fs-checks.ts'

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
  environment: Environment
  configFile: string
  spawn: SpawnPty
  // How the harness is started for a session.
  plan: (kind: TerminalKind) => Promise<SessionPlan>
  maxTerminals: number
  // Where the registrations of the runs in a terminal are kept, a folder for each.
  sessionsRoot: string
  // Follows the conversations of the harnesses started in a terminal.
  watch?: typeof watchTranscripts
  // The environment of the user's login shell, read for each harness that is started, so
  // that what the user's start-up files export reaches it; the real one asks the shell.
  loginEnvironment?: () => Promise<Record<string, string> | null>
}

// Asks the user's own shell; there is none to ask on Windows.
function askLoginShell(environment: Environment): Promise<Record<string, string> | null> {
  if (process.platform === 'win32') return Promise.resolve(null)
  const shell = environment.env.SHELL || (process.platform === 'darwin' ? '/bin/zsh' : '/bin/sh')
  return readLoginEnvironment(shell)
}

// Where the app keeps what it makes for the harnesses it injects Synapse into.
export function injectedDir(environment: Environment): string {
  const base = environment.env.XDG_DATA_HOME
    ? environment.env.XDG_DATA_HOME
    : join(environment.home, '.local', 'share')
  return join(base, 'synapse-desktop', 'injected')
}

// Where the registrations of the runs in the terminals are kept.
export function sessionsRoot(environment: Environment): string {
  return join(injectedDir(environment), '..', 'sessions')
}

// An interactive run is `synapse-pipeline` itself, whose harnesses use the terminal it is given.
function planPipeline(): SessionPlan {
  return { command: 'synapse-pipeline', args: [], env: {}, loaded: false, note: '' }
}

export function defaultPlan(environment: Environment): TerminalDeps['plan'] {
  return (kind) => {
    const deps = {
      env: environment.env,
      home: environment.home || homedir(),
      dataDir: injectedDir(environment),
    }
    if (kind === 'Pipeline') return Promise.resolve(planPipeline())
    return kind === 'Shell' ? planShell(deps) : planSession(kind, deps)
  }
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

// The id of an interactive run, in the form `synapse-pipeline` draws its own.
function drawRunId(): string {
  return `exec-${randomBytes(4).toString('hex')}`
}

// A refusal, with the code it is answered with.
export interface Prepared {
  pty: Pty
  cwd: string
  loaded: boolean
  note: string
  // The id of the run, for a terminal that started one.
  executionId?: string
  // Makes a harness run that this server started known, so that its conversation is followed.
  follow: ((watcher: Watcher) => void) | null
}

// Checks what a session is asked to be, and starts its program. `sessionsDir` is the folder the
// runs started in the terminal are noted in.
export async function prepare(
  message: TerminalStartParams,
  deps: TerminalDeps,
  sessionsDir: string,
): Promise<Prepared> {
  const refuse = (text: string) => new HostError('bad_request', text)
  const cwd = expandHome(message.cwd ?? deps.environment.home, deps.environment.home)
  if (!isAbsolute(cwd) || !(await isDirectory(cwd))) throw refuse(`${cwd} is not a folder`)
  if (message.kind === 'Pipeline') {
    if (message.pipeline === undefined) throw refuse('an interactive run needs a pipeline')
    if (message.task !== undefined || message.resume !== undefined) {
      throw refuse('a pipeline has no task or session to resume')
    }
  } else if (message.pipeline !== undefined || message.input !== undefined) {
    throw refuse('only an interactive run takes a pipeline')
  }
  if (message.task !== undefined && message.kind === 'Shell') {
    throw refuse('a shell has no task to start')
  }
  if (message.resume !== undefined && (message.kind === 'Shell' || message.task !== undefined)) {
    throw refuse('only a harness without a task has a session to resume')
  }
  const plan = await deps.plan(message.kind)
  const config = await loadConfig(deps.configFile, deps.environment)
  let args = plan.args
  let follow: Prepared['follow'] = null
  // The commands of a shell note the runs they start in this folder.
  const extra: Record<string, string> =
    message.kind === 'Shell' ? { SYNAPSE_SESSIONS_DIR: sessionsDir } : {}
  if (message.kind === 'Claude') {
    // A session of a name of our own, so that its file is known before it exists; a session that
    // is resumed has its own, and its file is the one that grows.
    const id = message.resume ?? randomUUID()
    args = [...args, ...(message.resume === undefined ? ['--session-id', id] : ['--resume', id])]
    follow = (watcher) =>
      watcher.register(id, { harness: 'claude', sessionId: id, cwd, startedAt: Date.now() })
  } else if (message.kind === 'Opencode') {
    // A session of an id of our own, which OpenCode makes when there is none: its messages
    // are asked for by it.
    // The same flag continues a session that is there.
    const id = message.resume ?? `ses_${randomBytes(10).toString('hex')}`
    args = [...args, '--session', id]
    follow = (watcher) =>
      watcher.register(id, { harness: 'opencode', sessionId: id, cwd, startedAt: Date.now() })
  } else if (message.kind === 'Codex' && message.resume !== undefined) {
    // A resumed session goes on in its own file, which is not one that appears after the start.
    args = [...args, 'resume', message.resume]
  } else if (message.kind === 'Codex') {
    follow = (watcher) =>
      watcher.register(`codex-${randomBytes(3).toString('hex')}`, {
        harness: 'codex',
        cwd,
        home: plan.env.CODEX_HOME,
        startedAt: Date.now(),
      })
  }
  if (message.task !== undefined && message.kind !== 'Pipeline') {
    args = [...args, ...taskArgs(message.kind, message.task)]
  }
  let executionId: string | undefined
  if (message.kind === 'Pipeline' && message.pipeline !== undefined) {
    if (config.workDir === null) throw new HostError('conflict', 'no work directory is set')
    executionId = drawRunId()
    args = [...args, 'run', message.pipeline, '--interactive', '--id', executionId]
    // The terminal is the harness's, so the input goes in a file of this connection's own.
    if (message.input !== undefined) {
      const file = join(sessionsDir, 'input.json')
      await mkdir(sessionsDir, { recursive: true })
      await writeFile(file, JSON.stringify(message.input))
      args = [...args, '--input', file]
    }
  }
  // A shell is the user's own and reads its start-up files itself; a harness is given what
  // they export.
  const base =
    message.kind === 'Shell'
      ? deps.environment.env
      : harnessEnvironment(
          await (deps.loginEnvironment ?? (() => askLoginShell(deps.environment)))(),
          deps.environment.env,
        )
  const env = {
    ...Object.fromEntries(
      Object.entries(strings(cliEnvironment(base, config))).filter(
        ([name]) => !OF_ANOTHER_SESSION.includes(name),
      ),
    ),
    ...plan.env,
    ...extra,
    TERM: 'xterm-256color',
  }
  let pty: Pty
  try {
    pty = deps.spawn(plan.command, args, { cwd, env, cols: message.cols, rows: message.rows })
  } catch (error) {
    throw new HostError('unavailable', `${plan.command} could not be started: ${String(error)}`)
  }
  return {
    pty,
    cwd,
    loaded: plan.loaded,
    note: plan.note,
    follow,
    ...(executionId === undefined ? {} : { executionId }),
  }
}
