// Running the Synapse binaries: only the subcommands listed here, never a shell.

import { execFile } from 'node:child_process'
import { delimiter } from 'node:path'
import type { AppConfig, CliBinary, CliResult } from '../shared/transport.ts'

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
  config: AppConfig
}

// The environment a Synapse binary runs in: the work directory and the
// definition directories the user set up in the app come before those the
// process already had.
export function cliEnvironment(base: NodeJS.ProcessEnv, config: AppConfig): NodeJS.ProcessEnv {
  const env = { ...base }
  if (config.workDir !== null) env.SYNAPSE_WORK_DIR = config.workDir
  if (config.definitionPaths.length > 0) {
    const inherited = (base.SYNAPSE_PIPELINE_PATH ?? '').split(delimiter)
    env.SYNAPSE_PIPELINE_PATH = [...config.definitionPaths, ...inherited]
      .filter(Boolean)
      .join(delimiter)
  }
  return env
}

export type CliRunner = (run: CliRun) => Promise<CliResult>

// The binary is looked up on PATH. A non-zero exit is a result, not an error.
export const runCli: CliRunner = ({ binary, args, stdin, config }) =>
  new Promise((resolve, reject) => {
    const env = cliEnvironment(process.env, config)
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
