// Running the Synapse binaries: only the subcommands listed here, never a shell.

import { execFile } from 'node:child_process'
import { delimiter } from 'node:path'
import type { AppConfig, CliBinary, CliResult } from '../shared/transport.ts'

// What `cli` may run. Starting a run is `startRun`, not a subcommand of this.
const ALLOWED_SUBCOMMANDS: Record<CliBinary, readonly string[]> = {
  'synapse-pipeline': ['check', 'show', 'list', 'info', 'cleanup'],
  synapse: [
    'config',
    'status',
    'vault-list',
    'vault-read',
    'vault-search',
    'vault-search-text',
    'vault-links',
    'vault-backlinks',
    'work-dir',
    'callers',
    'index',
  ],
}

const MAX_ARGS = 32
const MAX_ARG_LENGTH = 4096
const TIMEOUT_MS = 30_000
const MAX_OUTPUT_BYTES = 8 * 1024 * 1024

// A setting's name: capitals, digits and underscores.
const SETTING_KEY = /^[A-Z][A-Z0-9_]*$/

// `config list [--format json|text]`, `config set <KEY> <value>` and
// `config unset <KEY>`, and nothing else of `synapse config`.
function refuseConfig(args: readonly string[]): string | null {
  const [, action, ...rest] = args
  if (action === 'list') {
    const plain = rest.length === 0
    const formatted =
      rest.length === 2 && rest[0] === '--format' && ['json', 'text'].includes(rest[1] ?? '')
    return plain || formatted ? null : 'config list takes only --format json or text'
  }
  if (action === 'set') {
    return rest.length === 2 && SETTING_KEY.test(rest[0] ?? '')
      ? null
      : 'config set takes a setting name and a value'
  }
  if (action === 'unset') {
    return rest.length === 1 && SETTING_KEY.test(rest[0] ?? '')
      ? null
      : 'config unset takes a setting name'
  }
  return 'config takes list, set or unset'
}

// `status [--format json|text]`, and nothing else of `synapse status`.
function refuseStatus(args: readonly string[]): string | null {
  const [, ...rest] = args
  if (rest.length === 0) return null
  const formatted =
    rest.length === 2 && rest[0] === '--format' && ['json', 'text'].includes(rest[1] ?? '')
  return formatted ? null : 'status takes only --format json or text'
}

// The read-only commands of the vault. `vault-list` takes nothing; each of the
// others takes one argument that is not a flag, a note's path or a search.
function refuseVault(args: readonly string[]): string | null {
  const [subcommand, ...rest] = args
  if (subcommand === 'vault-list') {
    return rest.length === 0 ? null : 'vault-list takes no arguments'
  }
  // A search by a rule on standard input names the columns it wants back.
  if (subcommand === 'vault-search') {
    const fields = rest[1] ?? ''
    return rest.length === 2 && rest[0] === '--fields' && /^[A-Za-z0-9_.,-]{1,200}$/.test(fields)
      ? null
      : 'vault-search takes only --fields and a list of fields'
  }
  if (rest.length !== 1 || (rest[0] ?? '').startsWith('-') || (rest[0] ?? '') === '') {
    return `${subcommand ?? 'the command'} takes one argument that is not a flag`
  }
  return null
}

// A namespace is `<repo>@<branch>`, a folder's name: no separator, no dots alone.
const NAMESPACE = /^[A-Za-z0-9._+-]{1,128}@[A-Za-z0-9._+-]{1,128}$/

// A search term or a path: one argument that is not a flag.
function plain(arg: string | undefined, max: number): boolean {
  return arg !== undefined && arg !== '' && !arg.startsWith('-') && arg.length <= max
}

// The reads of a graph's local files, always of one namespace named by
// `--namespace`: `callers <name> [--all]`, `index lookup <path>` and
// `index nodes|paths|unassigned`; and `work-dir --list` or `--root`.
function refuseGraph(args: readonly string[]): string | null {
  const [subcommand, ...rest] = args
  const named = (own: readonly string[]): boolean => {
    const at = own.length
    return (
      rest.length === at + 2 && rest[at] === '--namespace' && NAMESPACE.test(rest[at + 1] ?? '')
    )
  }
  if (subcommand === 'work-dir') {
    return rest.length === 1 && (rest[0] === '--list' || rest[0] === '--root')
      ? null
      : 'work-dir takes only --list or --root'
  }
  if (subcommand === 'callers') {
    const all = rest[1] === '--all'
    const ok = plain(rest[0], 512) && named(all ? [rest[0] ?? '', '--all'] : [rest[0] ?? ''])
    return ok ? null : 'callers takes a name, --all and --namespace <repo>@<branch>'
  }
  // `index`
  const [action, ...more] = rest
  if (action === 'lookup') {
    return plain(more[0], 4096) &&
      more.length === 3 &&
      more[1] === '--namespace' &&
      NAMESPACE.test(more[2] ?? '')
      ? null
      : 'index lookup takes a path and --namespace <repo>@<branch>'
  }
  if (action === 'nodes' || action === 'paths' || action === 'unassigned') {
    return more.length === 2 && more[0] === '--namespace' && NAMESPACE.test(more[1] ?? '')
      ? null
      : `index ${action} takes --namespace <repo>@<branch>`
  }
  return 'index takes lookup, nodes, paths or unassigned'
}

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
  if (binary !== 'synapse') return null
  if (subcommand === 'status') return refuseStatus(args)
  if (subcommand?.startsWith('vault-')) return refuseVault(args)
  if (subcommand === 'work-dir' || subcommand === 'callers' || subcommand === 'index') {
    return refuseGraph(args)
  }
  return refuseConfig(args)
}

export interface CliRun {
  binary: CliBinary
  args: readonly string[]
  stdin?: string
  config: AppConfig
  // Variables set after the others, to point the program somewhere else.
  env?: Record<string, string>
}

// The environment a Synapse binary runs in: the work directory and the
// definition directories the user set up in the app come before those the
// process already had, and the variables the user set are over all of it.
export function cliEnvironment(base: NodeJS.ProcessEnv, config: AppConfig): NodeJS.ProcessEnv {
  const env = { ...base }
  if (config.workDir !== null) env.SYNAPSE_WORK_DIR = config.workDir
  if (config.definitionPaths.length > 0) {
    const inherited = (base.SYNAPSE_PIPELINE_PATH ?? '').split(delimiter)
    env.SYNAPSE_PIPELINE_PATH = [...config.definitionPaths, ...inherited]
      .filter(Boolean)
      .join(delimiter)
  }
  // The variables the user set in the app come last, so that they win.
  return { ...env, ...config.env }
}

export type CliRunner = (run: CliRun) => Promise<CliResult>

// The binary is looked up on PATH. A non-zero exit is a result, not an error.
export const runCli: CliRunner = ({ binary, args, stdin, config, env: extra }) =>
  new Promise((resolve, reject) => {
    const env = { ...cliEnvironment(process.env, config), ...extra }
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
