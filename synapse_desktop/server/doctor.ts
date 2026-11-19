// What `synapse doctor --install` says of the setup: the programs, the harnesses, the
// configuration and the vault. The harnesses are looked for on the PATH of the user's
// login shell as well as the one this server has, because a program started from the
// desktop has the short one the system gives it, and a terminal has the one the user's
// own files make.

import { execFile } from 'node:child_process'
import { delimiter } from 'node:path'
import { z } from 'zod'
import type { AppConfig, Diagnosis } from '../shared/transport.ts'
import type { CliRunner } from './cli.ts'

const documentSchema = z.object({
  format: z.literal('synapse-doctor/v1'),
  checks: z.array(
    z.object({
      key: z.string(),
      name: z.string(),
      status: z.enum(['ok', 'warn', 'fail']),
      detail: z.string(),
      value: z.string(),
    }),
  ),
  counts: z.object({ ok: z.number(), warn: z.number(), fail: z.number() }),
})

const MARK = '__SYNAPSE_PATH__'
const LOOK_MS = 5000

// The PATH a login shell has, or null when it cannot be had. The shell is asked as an
// interactive login shell, the way a terminal is started, so that what its start-up files
// add is there; it is told to mark the answer, since those files may print.
export function readLoginPath(shell: string): Promise<string | null> {
  return new Promise((resolve) => {
    execFile(
      shell,
      // `${PATH}` in braces: `$PATH__SYNAPSE...` would be read as one variable of that name.
      ['-ilc', `printf '%s' "${MARK}\${PATH}${MARK}"`],
      { timeout: LOOK_MS, env: process.env },
      (error, stdout) => {
        if (error !== null && stdout === '') return resolve(null)
        const start = stdout.indexOf(MARK)
        const end = stdout.lastIndexOf(MARK)
        if (start === -1 || end <= start) return resolve(null)
        resolve(stdout.slice(start + MARK.length, end) || null)
      },
    )
  })
}

const ENV_MARK = '__SYNAPSE_ENV__'
const ENV_BUFFER = 4 * 1024 * 1024

// The variables that describe the shell the environment was read from, not the user's
// settings, and those of the shell terminal's own start-up.
export const SHELL_INTERNAL: readonly string[] = [
  'PWD',
  'OLDPWD',
  'SHLVL',
  '_',
  'TERM',
  'ZDOTDIR',
  'SYNAPSE_USER_ZDOTDIR',
  'SYNAPSE_SHIM_DIR',
]

// The whole environment a login shell has, or null when it cannot be had. The shell is
// asked as an interactive login shell, so that what its start-up files export is there.
// `printf` and `env` are named by their paths so that no shell's built-in of the same name
// answers instead, and `;` parts the commands in every shell; the answer is marked, since
// the start-up files may print, and its entries are parted by NUL, so that a value may hold
// a newline.
export function readLoginEnvironment(shell: string): Promise<Record<string, string> | null> {
  const script = `/usr/bin/printf '%s' ${ENV_MARK}; /usr/bin/env -0; /usr/bin/printf '%s' ${ENV_MARK}`
  return new Promise((resolve) => {
    const child = execFile(
      shell,
      ['-ilc', script],
      { timeout: LOOK_MS, maxBuffer: ENV_BUFFER, env: process.env },
      (_error, stdout) => resolve(parseLoginEnvironment(stdout)),
    )
    // Nothing is typed to it, so a start-up file that asks does not wait for an answer.
    child.stdin?.end()
  })
}

// The variables between the first and the last mark of `stdout`, an entry for each
// NUL-ended `NAME=value`; null when the marks are not there or nothing is between them.
export function parseLoginEnvironment(stdout: string): Record<string, string> | null {
  const start = stdout.indexOf(ENV_MARK)
  const end = stdout.lastIndexOf(ENV_MARK)
  if (start === -1 || end <= start) return null
  const variables: Record<string, string> = {}
  for (const entry of stdout.slice(start + ENV_MARK.length, end).split('\0')) {
    const equals = entry.indexOf('=')
    if (equals <= 0) continue
    variables[entry.slice(0, equals)] = entry.slice(equals + 1)
  }
  return Object.keys(variables).length > 0 ? variables : null
}

// The environment a harness is started with: the login shell's, without the variables of
// the shell itself, its PATH first and then the directories only this host has; this
// host's own when the login shell's could not be had.
export function harnessEnvironment(
  captured: Record<string, string> | null,
  own: Record<string, string | undefined>,
): Record<string, string | undefined> {
  if (captured === null) return own
  const environment: Record<string, string | undefined> = Object.fromEntries(
    Object.entries(captured).filter(([name]) => !SHELL_INTERNAL.includes(name)),
  )
  environment.PATH = combinedPath(captured.PATH, own.PATH)
  return environment
}

// The directories of `first`, then those of `then` that are not there.
export function combinedPath(
  first: string | null | undefined,
  then: string | null | undefined,
): string {
  const seen = new Set<string>()
  const dirs: string[] = []
  for (const dir of [...(first ?? '').split(delimiter), ...(then ?? '').split(delimiter)]) {
    if (dir === '' || seen.has(dir)) continue
    seen.add(dir)
    dirs.push(dir)
  }
  return dirs.join(delimiter)
}

export interface DoctorDeps {
  runCli: CliRunner
  // The PATH of the login shell; the real one reads it from the user's shell.
  loginPath?: () => Promise<string | null>
  env?: NodeJS.ProcessEnv
  platform?: NodeJS.Platform
}

// A login shell can be slow to start, and its PATH does not change while the app is looked
// at, so the answer is kept for a little while.
const KEEP_MS = 30_000
let kept: { at: number; shell: string; path: string | null } | null = null

export async function loginShellPath(env: NodeJS.ProcessEnv, platform: NodeJS.Platform) {
  if (platform === 'win32') return null
  const shell = env.SHELL ?? '/bin/sh'
  if (kept !== null && kept.shell === shell && Date.now() - kept.at < KEEP_MS) return kept.path
  const path = await readLoginPath(shell)
  kept = { at: Date.now(), shell, path }
  return path
}

export function forgetLoginPath(): void {
  kept = null
}

export async function diagnose(config: AppConfig, deps: DoctorDeps): Promise<Diagnosis> {
  const env = deps.env ?? process.env
  const login = await (
    deps.loginPath ?? (() => loginShellPath(env, deps.platform ?? process.platform))
  )()
  const result = await deps.runCli({
    binary: 'synapse',
    args: ['doctor', '--install', '--format', 'json'],
    config,
    // This host's PATH first, so that its own `synapse` is the one asked, not another copy the
    // login shell finds; the login shell's directories after it, for the harnesses only it can find.
    env: { PATH: combinedPath(env.PATH, login) },
  })
  // A failure is a finding with exit code 1, and is printed all the same. Nothing printed is
  // the program not running at all.
  let json: unknown
  try {
    json = JSON.parse(result.stdout)
  } catch {
    const why = (result.stderr || result.stdout).trim()
    throw new Error(why === '' ? 'synapse doctor printed nothing' : why)
  }
  const parsed = documentSchema.safeParse(json)
  if (!parsed.success) throw new Error('synapse doctor answered in a format this app does not know')
  return { findings: parsed.data.checks, counts: parsed.data.counts }
}
