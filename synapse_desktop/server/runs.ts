// Starting a run and stopping it. The server draws the run's id and gives it
// to `synapse-pipeline run --id`, so the run is known by its id from the start:
// its record directory, named by the id, is made as the run begins.

import { spawn, type ChildProcess } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { isAbsolute, join } from 'node:path'
import type { AppConfig } from '../shared/transport.ts'
import { cliEnvironment } from './cli.ts'

const POLL_MS = 50
const FIND_TIMEOUT_MS = 10_000
const MAX_STDERR_BYTES = 8192

export class NotStartedHere extends Error {}
export class RunNotStarted extends Error {}
// The folder the run was to work in is not an absolute path, or not a directory.
export class FolderNotFound extends RunNotStarted {}

// An id in the form the program draws its own, so that the app's runs and the
// others look alike.
function drawId(): string {
  return `exec-${randomBytes(4).toString('hex')}`
}

async function isDirectory(path: string): Promise<boolean> {
  return (await stat(path).catch(() => null))?.isDirectory() ?? false
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
  // A missing or blank folder is the user's home folder.
  start(
    pipeline: string,
    input: unknown,
    config: AppConfig,
    folder?: string,
  ): Promise<{ executionId: string }>
  stop(executionId: string): void
}

// `binary` is looked up on PATH unless it is a path. `home` is the folder a run
// works in when it is given none.
export function createRunStarter(
  binary: string,
  baseEnv: NodeJS.ProcessEnv,
  home: string = homedir(),
): RunStarter {
  const children = new Map<string, ChildProcess>()

  return {
    async start(pipeline, input, config, folder) {
      if (config.workDir === null) throw new RunNotStarted('no work directory is set')
      const cwd = folder === undefined || folder.trim() === '' ? home : folder
      // A relative folder would resolve against this process's own folder.
      if (!isAbsolute(cwd)) throw new FolderNotFound(`the folder ${cwd} is not an absolute path`)
      if (!(await isDirectory(cwd))) throw new FolderNotFound(`the folder ${cwd} does not exist`)
      const id = drawId()
      const record = join(config.workDir, 'pipelines', id)

      const child = spawn(binary, ['run', pipeline, '--input', '-', '--id', id], {
        cwd,
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

      // The run makes its record directory as it begins; a run that is refused
      // exits without making it, and says why on standard error.
      const deadline = Date.now() + FIND_TIMEOUT_MS
      for (;;) {
        if (await isDirectory(record)) {
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
