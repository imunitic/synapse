// What each harness has installed of Synapse, and the Synapse this app would
// install: found in the harnesses' own files and as the programs on PATH.

import { execFile } from 'node:child_process'
import { readFile, realpath, stat } from 'node:fs/promises'
import { basename, dirname, join, resolve } from 'node:path'
import type {
  BundledSynapse,
  Harness,
  Integration,
  IntegrationState,
  Integrations,
} from '../shared/transport.ts'
import { findContentRoot, findExecutable } from './inject.ts'

const HOOK_NAME = 'synapse-hook'
const EXE = process.platform === 'win32' ? '.exe' : ''

export interface IntegrationDeps {
  env: Record<string, string | undefined>
  home: string
  // The version a program says it is, or null when it cannot be run.
  versionOf: (program: string) => Promise<string | null>
}

async function isFile(path: string): Promise<boolean> {
  return (await stat(path).catch(() => null))?.isFile() ?? false
}

async function isDirectory(path: string): Promise<boolean> {
  return (await stat(path).catch(() => null))?.isDirectory() ?? false
}

// The first word of a hook command when it names the hook program.
function hookIn(command: unknown): string | null {
  if (typeof command !== 'string') return null
  const [program] = command.split(' ')
  if (program === undefined) return null
  const name = basename(program.replaceAll('\\', '/'), '.exe')
  return name === HOOK_NAME ? program : null
}

function firstHookOf(hooks: unknown): string | null {
  if (typeof hooks !== 'object' || hooks === null) return null
  for (const groups of Object.values(hooks)) {
    if (!Array.isArray(groups)) continue
    for (const group of groups as { hooks?: { command?: unknown }[] }[]) {
      for (const hook of group?.hooks ?? []) {
        const found = hookIn(hook?.command)
        if (found !== null) return found
      }
    }
  }
  return null
}

// The hook program the harness runs, as its configuration names it.
export async function hookOf(harness: Harness, home: string): Promise<string | null> {
  if (harness === 'Opencode') {
    const text = await readFile(
      join(home, '.config', 'opencode', 'plugin', 'synapse.js'),
      'utf8',
    ).catch(() => '')
    const literal = /SYNAPSE_HOOK_BIN\s*\|\|\s*("(?:[^"\\]|\\.)*")/.exec(text)?.[1]
    if (literal === undefined) return null
    try {
      const path: unknown = JSON.parse(literal)
      return typeof path === 'string' && path !== '__SYNAPSE_HOOK_BIN__' ? path : null
    } catch {
      return null
    }
  }
  const file =
    harness === 'Claude'
      ? join(home, '.claude', 'settings.json')
      : join(home, '.codex', 'hooks.json')
  try {
    const json = JSON.parse(await readFile(file, 'utf8')) as { hooks?: unknown }
    return firstHookOf(json.hooks)
  } catch {
    return null
  }
}

// What `program --version` prints after the program's name.
export function versionOfProgram(program: string): Promise<string | null> {
  return new Promise((done) => {
    execFile(program, ['--version'], { timeout: 5000 }, (error, stdout) => {
      done(error ? null : (/^\S+ (\S+)/m.exec(stdout)?.[1] ?? null))
    })
  })
}

// The folder of the `synapse-pipeline` package, with its skills: named by the
// launcher on PATH, else the one of this checkout.
export async function findPipelineRoot(
  env: Record<string, string | undefined>,
): Promise<string | null> {
  const candidates: string[] = []
  const launcher = await findExecutable('synapse-pipeline', env.PATH ?? '')
  if (launcher !== null) {
    const real = await realpath(launcher).catch(() => null)
    if (real !== null) candidates.push(join(dirname(real), '..'))
  }
  candidates.push(resolve(import.meta.dirname, '..', '..', 'packages', 'synapse-pipeline'))
  for (const candidate of candidates) {
    if (await isDirectory(join(candidate, 'skills'))) return resolve(candidate)
  }
  return null
}

async function same(a: string, b: string): Promise<boolean> {
  const [x, y] = await Promise.all([realpath(a).catch(() => a), realpath(b).catch(() => b)])
  return x === y
}

async function bundled(deps: IntegrationDeps): Promise<BundledSynapse> {
  const program = await findExecutable('synapse', deps.env.PATH ?? '')
  const hook = program === null ? null : join(dirname(program), HOOK_NAME + EXE)
  return {
    version: program === null ? null : await deps.versionOf(program),
    hook: hook !== null && (await isFile(hook)) ? hook : null,
    contentRoot: await findContentRoot(deps.env),
    pipelineRoot: await findPipelineRoot(deps.env),
  }
}

async function integration(
  harness: Harness,
  have: BundledSynapse,
  deps: IntegrationDeps,
): Promise<Integration> {
  const hook = await hookOf(harness, deps.home)
  if (hook === null) return { harness, state: 'absent', hook: null, version: null }
  if (!(await isFile(hook))) return { harness, state: 'broken', hook, version: null }
  const version = await deps.versionOf(join(dirname(hook), 'synapse' + EXE))
  let state: IntegrationState = 'installed'
  if (have.hook !== null) {
    state =
      (await same(hook, have.hook)) || (version !== null && version === have.version)
        ? 'current'
        : 'different'
  }
  return { harness, state, hook, version }
}

export async function inspectIntegrations(deps: IntegrationDeps): Promise<Integrations> {
  const have = await bundled(deps)
  const harnesses = await Promise.all(
    (['Claude', 'Codex', 'Opencode'] as const).map((h) => integration(h, have, deps)),
  )
  return { bundled: have, harnesses }
}
