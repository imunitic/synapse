// Starting a run and stopping it. `synapse-pipeline run` prints no execution
// id before it ends, so the run is found by its record: the new directory whose
// summary names this pipeline and holds this input.

import { spawn, type ChildProcess } from 'node:child_process'
import { readdir, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { AppConfig } from '../shared/transport.ts'
import { cliEnvironment } from './cli.ts'

const POLL_MS = 50
const FIND_TIMEOUT_MS = 10_000
const MAX_STDERR_BYTES = 8192

export class NotStartedHere extends Error {}
export class RunNotStarted extends Error {}

// JSON with the keys of every object in order, so two documents that mean the
// same thing give the same text.
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`
  if (value !== null && typeof value === 'object') {
    const entries = Object.entries(value).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(',')}}`
  }
  return JSON.stringify(value) ?? 'null'
}

// Whether a record's summary is the run of this pipeline with this input.
export function isRunOf(summary: unknown, pipeline: string, input: unknown): boolean {
  if (summary === null || typeof summary !== 'object') return false
  const { pipeline: named, state } = summary as { pipeline?: unknown; state?: unknown }
  if (named !== pipeline || state === null || typeof state !== 'object') return false
  const initial = (state as { initial_input?: unknown }).initial_input
  return canonical(initial) === canonical(input)
}

async function recordNames(recordsDir: string): Promise<string[]> {
  const entries = await readdir(recordsDir, { withFileTypes: true }).catch(() => [])
  return entries.filter((e) => e.isDirectory()).map((e) => e.name)
}

async function findRecord(
  recordsDir: string,
  before: ReadonlySet<string>,
  pipeline: string,
  input: unknown,
): Promise<string | null> {
  for (const name of await recordNames(recordsDir)) {
    if (before.has(name)) continue
    const text = await readFile(join(recordsDir, name, 'execution.json'), 'utf8').catch(() => null)
    if (text === null) continue
    try {
      if (isRunOf(JSON.parse(text), pipeline, input)) return name
    } catch {
      continue
    }
  }
  return null
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

// Ends the process and everything it started. The `synapse-pipeline` that is
// on PATH after an npm install is a shim that runs the real binary as its
// child and passes no signal on, so killing the shim alone leaves the run going.
function killTree(child: ChildProcess): void {
  const { pid } = child
  if (pid === undefined) return
  if (process.platform === 'win32') {
    spawn('taskkill', ['/pid', String(pid), '/T', '/F'], { stdio: 'ignore' })
    return
  }
  try {
    process.kill(-pid, 'SIGTERM')
  } catch {
    child.kill('SIGTERM')
  }
}

export interface RunStarter {
  start(pipeline: string, input: unknown, config: AppConfig): Promise<{ executionId: string }>
  stop(executionId: string): void
}

// `binary` is looked up on PATH unless it is a path.
export function createRunStarter(binary: string, baseEnv: NodeJS.ProcessEnv): RunStarter {
  const children = new Map<string, ChildProcess>()

  return {
    async start(pipeline, input, config) {
      if (config.workDir === null) throw new RunNotStarted('no work directory is set')
      const recordsDir = join(config.workDir, 'pipelines')
      const before = new Set(await recordNames(recordsDir))

      const child = spawn(binary, ['run', pipeline, '--input', '-'], {
        env: cliEnvironment(baseEnv, config),
        stdio: ['pipe', 'ignore', 'pipe'],
        // Its own process group, so that stop can end the whole tree.
        detached: process.platform !== 'win32',
      })
      let stderr = ''
      let exited = false
      let spawnError: Error | null = null
      child.stderr.on('data', (chunk: Buffer) => {
        if (stderr.length < MAX_STDERR_BYTES) stderr += chunk.toString()
      })
      child.on('error', (error) => (spawnError = error))
      child.on('exit', () => (exited = true))
      child.stdin.on('error', () => undefined)
      child.stdin.end(JSON.stringify(input))

      const deadline = Date.now() + FIND_TIMEOUT_MS
      for (;;) {
        const id = await findRecord(recordsDir, before, pipeline, input)
        if (id !== null) {
          children.set(id, child)
          child.on('exit', () => children.delete(id))
          return { executionId: id }
        }
        if (spawnError !== null) throw new RunNotStarted(`${binary} could not be run`)
        if (exited || Date.now() > deadline) {
          killTree(child)
          throw new RunNotStarted(stderr.trim() || 'the run left no record')
        }
        await sleep(POLL_MS)
      }
    },

    stop(executionId) {
      const child = children.get(executionId)
      if (child === undefined) throw new NotStartedHere('this run was not started by this app')
      killTree(child)
    },
  }
}
