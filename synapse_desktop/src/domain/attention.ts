// What needs a person's attention, put together from what the pages already
// know: the vault's own report, the runs, the harnesses and the settings. Each
// source is read on its own, so one that fails does not hide the others.

import { z } from 'zod'
import type { AppConfig, Integration, Transport } from '../../shared/transport.ts'
import type { ExecutionSummary } from './executions.ts'
import { HARNESS_NAMES } from './integrations.ts'

const categorySchema = z.object({
  key: z.string(),
  title: z.string(),
  items: z.array(
    z.looseObject({
      path: z.string(),
      id: z.string().nullable(),
      title: z.string(),
      compiled_task: z.string().nullable().optional(),
      unchecked: z.number().optional(),
    }),
  ),
})

const statusSchema = z.object({
  format: z.literal('synapse-status/v1'),
  vault: z.string(),
  clear: z.boolean(),
  categories: z.array(categorySchema),
})

export type VaultCategory = z.infer<typeof categorySchema>

// What `synapse status` says: the vault's categories, or that no vault is set.
export type VaultAttention =
  { configured: true; vault: string; categories: VaultCategory[] } | { configured: false }

// Throws when `synapse` cannot be run or answers in a form this app does not know.
export async function loadVaultAttention(transport: Transport): Promise<VaultAttention> {
  const result = await transport.cli('synapse', ['status', '--format', 'json'])
  if (result.code !== 0) {
    if (result.stderr.includes('no vault')) return { configured: false }
    throw new Error(result.stderr.trim() === '' ? 'status failed' : result.stderr.trim())
  }
  let json: unknown
  try {
    json = JSON.parse(result.stdout)
  } catch {
    throw new Error('status did not answer JSON')
  }
  const parsed = statusSchema.safeParse(json)
  if (!parsed.success) throw new Error('status answered a form this app does not know')
  return { configured: true, vault: parsed.data.vault, categories: parsed.data.categories }
}

// Where an item leads, when the app has a page for it.
export type AttentionTarget =
  | { kind: 'settings'; section: 'general' | 'vault' | 'integrations' }
  | { kind: 'execution'; id: string }
  | { kind: 'note'; path: string }

export interface AttentionItem {
  key: string
  // The note's own id, which the page sets apart from its title.
  id: string | null
  label: string
  detail: string | null
  target: AttentionTarget | null
}

export interface AttentionGroup {
  key: string
  title: string
  items: AttentionItem[]
}

// What a source gave, or why it could not.
export type Source<T> =
  { status: 'loading' } | { status: 'ready'; data: T } | { status: 'failed'; error: string }

export interface AttentionInputs {
  config: Source<AppConfig>
  vault: Source<VaultAttention>
  runs: Source<ExecutionSummary[]>
  integrations: Source<Integration[]>
  now: Date
}

// A run older than this is not news.
export const RUN_AGE_DAYS = 7
const MAX_RUNS = 10

function recent(run: ExecutionSummary, now: Date): boolean {
  if (run.started === null) return false
  const started = Date.parse(run.started)
  return !Number.isNaN(started) && now.getTime() - started <= RUN_AGE_DAYS * 86_400_000
}

function runItem(run: ExecutionSummary): AttentionItem {
  const name = run.pipeline ?? 'A pipeline'
  return {
    key: `run:${run.id}`,
    id: null,
    label: run.status === 'failed' ? `${name} failed` : `${name} was interrupted`,
    detail:
      run.status === 'failed' && run.failure !== null
        ? run.failureStep !== null
          ? `${run.failureStep}: ${run.failure}`
          : run.failure
        : null,
    target: { kind: 'execution', id: run.id },
  }
}

function vaultItems(vault: VaultAttention): AttentionGroup[] {
  if (!vault.configured) return []
  return vault.categories
    .filter((category) => category.items.length > 0)
    .map((category) => ({
      key: `vault:${category.key}`,
      title: category.title,
      items: category.items.map((item) => ({
        key: `${category.key}:${item.path}`,
        id: item.id,
        label: item.title,
        detail:
          category.key === 'open_questions'
            ? (item.compiled_task ?? null) !== null
              ? `Compiled task: ${item.compiled_task}`
              : 'Not compiled'
            : category.key === 'in_progress'
              ? `${item.unchecked ?? 0} unchecked`
              : null,
        target: { kind: 'note', path: item.path },
      })),
    }))
}

// The things to look at, in the order they are worth looking: a harness that
// is broken, then runs that went wrong, then the vault's decisions. What is not
// set up yet is the setup card's, not a fault. A source
// that failed is a problem of its own, and a source still loading says nothing.
export function attentionGroups(inputs: AttentionInputs): AttentionGroup[] {
  const groups: AttentionGroup[] = []

  const setup: AttentionItem[] = []
  if (inputs.integrations.status === 'ready') {
    for (const item of inputs.integrations.data) {
      if (item.state === 'broken') {
        setup.push({
          key: `harness:${item.harness}`,
          id: null,
          label: `${HARNESS_NAMES[item.harness]} names a hook program that is gone`,
          detail: item.hook,
          target: { kind: 'settings', section: 'integrations' },
        })
      }
    }
  }
  if (setup.length > 0) groups.push({ key: 'harnesses', title: 'Harnesses', items: setup })

  if (inputs.runs.status === 'ready') {
    const wrong = inputs.runs.data.filter(
      (run) => (run.status === 'failed' || run.status === 'interrupted') && recent(run, inputs.now),
    )
    if (wrong.length > 0) {
      const items = wrong.slice(0, MAX_RUNS).map(runItem)
      if (wrong.length > MAX_RUNS) {
        items.push({
          key: 'runs:more',
          id: null,
          label: `and ${wrong.length - MAX_RUNS} more`,
          detail: null,
          target: null,
        })
      }
      groups.push({ key: 'runs', title: 'Runs that went wrong', items })
    }
  }

  if (inputs.vault.status === 'ready') groups.push(...vaultItems(inputs.vault.data))
  return groups
}

// The sources that could not be read, and why.
export function attentionFailures(inputs: AttentionInputs): { source: string; error: string }[] {
  const failed: { source: string; error: string }[] = []
  const named: [string, Source<unknown>][] = [
    ['the vault', inputs.vault],
    ['the runs', inputs.runs],
    ['the harnesses', inputs.integrations],
    ['the settings', inputs.config],
  ]
  for (const [source, state] of named) {
    if (state.status === 'failed') failed.push({ source, error: state.error })
  }
  return failed
}

// Whether every source has answered.
export function isSettled(inputs: AttentionInputs): boolean {
  return [inputs.config, inputs.vault, inputs.runs, inputs.integrations].every(
    (s) => s.status !== 'loading',
  )
}
