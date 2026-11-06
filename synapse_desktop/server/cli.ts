// Running the Synapse binaries: only the subcommands listed here, never a shell.

import { execFile } from 'node:child_process'
import type { CliBinary, CliResult } from '../shared/transport.ts'

// What `cli` may run. Starting a run is `startRun`, not a subcommand of this.
const ALLOWED_SUBCOMMANDS: Record<CliBinary, readonly string[]> = {
  'synapse-pipeline': ['check', 'show', 'list', 'info', 'cleanup'],
  synapse: [],
}

const MAX_ARGS = 32
const MAX_ARG_LENGTH = 4096
const TIMEOUT_MS = 30_000
const MAX_OUTPUT_BYTES = 8 * 1024 * 1024

// The reason the call is refused, or null when it may run.
export function refuseCli(binary: CliBinary, args: readonly string[]): string | null {
  const [subcommand] = args
  if (subcommand === undefined) return 'a subcommand is required'
  if (!ALLOWED_SUBCOMMANDS[binary].includes(subcommand)) {
    return `${binary} ${subcommand} is not allowed`
  }
  if (args.length > MAX_ARGS) return 'too many arguments'
  if (args.some((a) => a.length > MAX_ARG_LENGTH || a.includes('\0'))) {
    return 'an argument is too long or holds a NUL'
  }
  return null
}

export interface CliRun {
  binary: CliBinary
  args: readonly string[]
  stdin?: string
  workDir: string | null
}

export type CliRunner = (run: CliRun) => Promise<CliResult>

// The binary is looked up on PATH. A non-zero exit is a result, not an error.
export const runCli: CliRunner = ({ binary, args, stdin, workDir }) =>
  new Promise((resolve, reject) => {
    const env = { ...process.env }
    if (workDir !== null) env.SYNAPSE_WORK_DIR = workDir
    const child = execFile(
      binary,
      [...args],
      { env, timeout: TIMEOUT_MS, maxBuffer: MAX_OUTPUT_BYTES },
      (error, stdout, stderr) => {
        if (error === null) {
          resolve({ code: 0, stdout, stderr })
        } else if (typeof error.code === 'number') {
          resolve({ code: error.code, stdout, stderr })
        } else {
          reject(new Error(`${binary} could not be run: ${error.message}`))
        }
      },
    )
    child.stdin?.end(stdin ?? '')
  })
