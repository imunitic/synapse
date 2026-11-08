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
      ['-ilc', `printf '%s' "${MARK}$PATH${MARK}"`],
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

// The directories of the login shell's PATH, then those of this process that are not there.
export function combinedPath(login: string | null, own: string | undefined): string {
  const seen = new Set<string>()
  const dirs: string[] = []
  for (const dir of [...(login ?? '').split(delimiter), ...(own ?? '').split(delimiter)]) {
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

async function loginShellPath(env: NodeJS.ProcessEnv, platform: NodeJS.Platform) {
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
    env: { PATH: combinedPath(login, env.PATH) },
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
