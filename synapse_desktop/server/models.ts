// The models a harness can be asked to use, read from the harness itself: OpenCode prints its
// catalogue, Codex renders its own as JSON, and Claude Code names its aliases when it is asked,
// in a session that does not call a model, what its `/model` command takes.

import { execFile } from 'node:child_process'
import { tmpdir } from 'node:os'
import { z } from 'zod'
import { MODEL_NAME } from '../shared/models.ts'
import type { Harness, ModelCatalog, ModelOption } from '../shared/transport.ts'
import { combinedPath, loginShellPath } from './doctor.ts'

const LOOK_MS = 20_000
const MAX_BYTES = 4 * 1024 * 1024

// A command that was run: its exit code and what it printed.
export type RunProgram = (
  program: string,
  args: readonly string[],
  env: NodeJS.ProcessEnv,
) => Promise<{ code: number; stdout: string }>

// eslint-disable-next-line no-control-regex -- the escape character is what starts a colour
const COLOUR = /\u001b\[[0-9;]*m/g

// The models in the output of `opencode models`: a line for each, `provider/model`.
export function parseOpencodeModels(stdout: string): { id: string; provider: string }[] {
  const found: { id: string; provider: string }[] = []
  const seen = new Set<string>()
  for (const raw of stdout.replace(COLOUR, '').split('\n')) {
    const id = raw.trim()
    const slash = id.indexOf('/')
    if (slash < 1 || slash === id.length - 1 || /\s/.test(id) || seen.has(id)) continue
    seen.add(id)
    found.push({ id, provider: id.slice(0, slash) })
  }
  return found
}

// The name a provider is listed by in `opencode models` from the name `opencode auth list` shows:
// `OpenRouter` is `openrouter`.
function slug(name: string): string {
  return name.toLowerCase().replace(/[^a-z0-9]/g, '')
}

// The providers OpenCode has credentials for, from `opencode auth list`: a line for each, its
// name first and then how it is connected, with lines around them that are not providers.
export function connectedProviders(authList: string): Set<string> {
  const names = new Set<string>()
  for (const raw of authList.replace(COLOUR, '').split('\n')) {
    const line = raw.trim()
    const row = /^([A-Za-z][A-Za-z0-9 ._-]*?)\s{2,}\S/.exec(line)
    if (row?.[1] !== undefined) names.add(slug(row[1]))
  }
  return names
}

// The provider that serves a model on OpenCode itself, which needs no credentials of the person's.
const OWN_PROVIDER = 'opencode'

export function opencodeCatalog(modelsOutput: string, authOutput: string): ModelCatalog {
  const connected = connectedProviders(authOutput)
  const models: ModelOption[] = parseOpencodeModels(modelsOutput).map(({ id, provider }) => ({
    id,
    provider,
    available: provider === OWN_PROVIDER || connected.has(slug(provider)),
    detail: null,
  }))
  // What can be used comes first, and then by name, by the code points of the names so that the order
  // is the same wherever it is read.
  models.sort(
    (a, b) => Number(b.available) - Number(a.available) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
  )
  const usable = models.filter((m) => m.available).length
  return {
    models,
    note:
      models.length === 0
        ? 'OpenCode listed no models.'
        : usable === models.length
          ? null
          : `${usable} of the ${models.length} models are of providers that are connected; the others need a login first.`,
  }
}

// The aliases Claude Code takes, from the answer of its `/model` command: `Current model: X` and
// `Usage: /model <name>. Available: a, b, c, or a full model ID.`
export function parseClaudeModels(stdout: string): { current: string | null; names: string[] } {
  const text = stdout.replace(COLOUR, '')
  const current = /Current model:\s*`?([^`\n]+?)`?\s*$/m.exec(text)?.[1] ?? null
  const list = /Available:\s*(.+?)(?:,?\s*or a full model ID)?\.?\s*$/m.exec(text)?.[1]
  const names = (list ?? '')
    .split(',')
    .map((name) => name.trim())
    .filter((name) => MODEL_NAME.test(name))
  return { current, names: [...new Set(names)] }
}

export function claudeCatalog(stdout: string): ModelCatalog {
  const { current, names } = parseClaudeModels(stdout)
  return {
    models: names.map((id) => ({ id, provider: null, available: true, detail: null })),
    note:
      names.length === 0
        ? null
        : `${current === null ? '' : `It is on ${current} now. `}Any full model ID can be typed as well.`,
  }
}

const codexCatalogSchema = z.object({
  models: z.array(
    z.object({
      slug: z.string(),
      display_name: z.string().optional(),
      description: z.string().optional(),
      visibility: z.string().optional(),
      priority: z.number().optional(),
    }),
  ),
})

// The models Codex lists, from its own catalogue as `codex debug models` renders it: the ones it
// shows in its `/model`, in the order it gives them. The ones it keeps out of that list can still
// be typed.
export function codexCatalog(stdout: string): ModelCatalog {
  let json: unknown
  try {
    json = JSON.parse(stdout)
  } catch {
    return { models: [], note: null }
  }
  const parsed = codexCatalogSchema.safeParse(json)
  if (!parsed.success) return { models: [], note: null }
  const shown = parsed.data.models
    .filter((m) => m.visibility === 'list' && MODEL_NAME.test(m.slug))
    .sort((a, b) => (a.priority ?? 1e9) - (b.priority ?? 1e9))
  return {
    models: shown.map((m) => ({
      id: m.slug,
      provider: null,
      available: true,
      detail:
        [m.display_name, m.description].filter((t) => t !== undefined && t !== '').join(': ') ||
        null,
    })),
    note: shown.length === 0 ? null : 'Any model name can be typed as well.',
  }
}

const NAMES: Record<Harness, string> = {
  Claude: 'Claude Code',
  Codex: 'Codex',
  Opencode: 'OpenCode',
}

// The session runs in an empty folder, so that the settings of no project are read into it.
const defaultRun: RunProgram = (program, args, env) =>
  new Promise((resolve) => {
    execFile(
      program,
      [...args],
      { env, cwd: tmpdir(), timeout: LOOK_MS, maxBuffer: MAX_BYTES },
      (error, stdout) => {
        resolve({
          code: error === null ? 0 : typeof error.code === 'number' ? error.code : 1,
          stdout,
        })
      },
    )
  })

// A list is long to read from a harness and does not change while the app is looked at. Only a list
// that was had is kept.
const KEEP_MS = 60_000
const kept = new Map<Harness, { at: number; catalog: ModelCatalog }>()

export function forgetModels(): void {
  kept.clear()
}

export interface ModelDeps {
  env?: NodeJS.ProcessEnv
  platform?: NodeJS.Platform
  run?: RunProgram
  // The PATH of the login shell, as the doctor finds it.
  loginPath?: () => Promise<string | null>
}

async function readCatalog(
  harness: Harness,
  run: RunProgram,
  env: NodeJS.ProcessEnv,
): Promise<ModelCatalog> {
  switch (harness) {
    case 'Opencode': {
      const [models, auth] = await Promise.all([
        run('opencode', ['models'], env),
        run('opencode', ['auth', 'list'], env),
      ])
      return models.code === 0
        ? opencodeCatalog(models.stdout, auth.code === 0 ? auth.stdout : '')
        : { models: [], note: null }
    }
    case 'Claude': {
      // A command of the session that is answered here, without a call to a model, and kept out of
      // the sessions the person has.
      const answer = await run('claude', ['-p', '/model', '--no-session-persistence'], env)
      return answer.code === 0 ? claudeCatalog(answer.stdout) : { models: [], note: null }
    }
    case 'Codex': {
      const answer = await run('codex', ['debug', 'models'], env)
      return answer.code === 0 ? codexCatalog(answer.stdout) : { models: [], note: null }
    }
  }
}

export async function listModels(harness: Harness, deps: ModelDeps = {}): Promise<ModelCatalog> {
  const known = kept.get(harness)
  if (known !== undefined && Date.now() - known.at < KEEP_MS) return known.catalog
  const env = deps.env ?? process.env
  const login = await (
    deps.loginPath ?? (() => loginShellPath(env, deps.platform ?? process.platform))
  )()
  const where = { ...env, PATH: combinedPath(login, env.PATH) }
  const catalog = await readCatalog(harness, deps.run ?? defaultRun, where)
  if (catalog.models.length === 0) {
    return {
      models: [],
      note: catalog.note ?? `${NAMES[harness]} could not list its models. Type a name instead.`,
    }
  }
  kept.set(harness, { at: Date.now(), catalog })
  return catalog
}
