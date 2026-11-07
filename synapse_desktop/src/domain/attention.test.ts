import { describe, expect, it } from 'vitest'
import type { AppConfig, CliResult, Integration, Transport } from '../../shared/transport.ts'
import {
  attentionFailures,
  attentionGroups,
  isSettled,
  loadVaultAttention,
  type AttentionInputs,
  type VaultAttention,
} from './attention.ts'
import type { ExecutionSummary } from './executions.ts'

function transportAnswering(result: CliResult): { transport: Transport; calls: unknown[][] } {
  const calls: unknown[][] = []
  const transport = {
    cli: (...args: unknown[]) => {
      calls.push(args)
      return Promise.resolve(result)
    },
  } as unknown as Transport
  return { transport, calls }
}

const status = {
  format: 'synapse-status/v1',
  vault: '/v',
  clear: false,
  categories: [
    {
      key: 'discussing',
      title: 'Discussing',
      items: [{ path: 'designs/a.md', id: 'p-1', title: 'Talk' }],
    },
    { key: 'ready_uncompiled', title: 'Ready, not yet compiled', items: [] },
    {
      key: 'open_questions',
      title: 'Open questions',
      items: [
        { path: 'designs/b.md', id: 'p-2', title: 'Asks', compiled_task: null },
        { path: 'designs/c.md', id: null, title: 'Going', compiled_task: 'Going task' },
      ],
    },
    {
      key: 'in_progress',
      title: 'In progress (unchecked items)',
      items: [{ path: 'tasks/t.md', id: 'p-3', title: 'Work', unchecked: 4 }],
    },
    { key: 'awaiting_review', title: 'Awaiting review', items: [] },
  ],
}

describe('the vault report', () => {
  it('is read from synapse status as JSON', async () => {
    const { transport, calls } = transportAnswering({
      code: 0,
      stdout: JSON.stringify(status),
      stderr: '',
    })
    const result = await loadVaultAttention(transport)
    expect(calls[0]).toEqual(['synapse', ['status', '--format', 'json']])
    expect(result.configured).toBe(true)
    expect(result.configured && result.categories).toHaveLength(5)
  })

  it('says no vault is configured when synapse does', async () => {
    const { transport } = transportAnswering({
      code: 1,
      stdout: '',
      stderr: 'synapse-status: no vault\n',
    })
    expect(await loadVaultAttention(transport)).toEqual({ configured: false })
  })

  it('fails with the reason when it cannot be read', async () => {
    await expect(
      loadVaultAttention(transportAnswering({ code: 1, stdout: '', stderr: 'boom\n' }).transport),
    ).rejects.toThrow('boom')
    await expect(
      loadVaultAttention(transportAnswering({ code: 0, stdout: 'not json', stderr: '' }).transport),
    ).rejects.toThrow('did not answer JSON')
    await expect(
      loadVaultAttention(
        transportAnswering({ code: 0, stdout: '{"format":"other/v9"}', stderr: '' }).transport,
      ),
    ).rejects.toThrow('form this app does not know')
  })
})

const NOW = new Date('2026-11-08T12:00:00Z')

const config = (workDir: string | null): AppConfig => ({
  workDir,
  definitionPaths: [],
  defaultHarness: null,
  env: {},
  recentVaults: [],
  terminalFolder: null,
})

function run(
  id: string,
  state: ExecutionSummary['status'],
  started: string | null,
  extra: Partial<ExecutionSummary> = {},
): ExecutionSummary {
  return {
    id,
    pipeline: 'Ship',
    status: state,
    started,
    ended: null,
    currentStep: null,
    stepsRun: null,
    failure: null,
    failureStep: null,
    fired: [],
    ...extra,
  }
}

const quiet: AttentionInputs = {
  config: { status: 'ready', data: config('/work') },
  vault: { status: 'ready', data: { configured: true, vault: '/v', categories: [] } },
  runs: { status: 'ready', data: [] },
  integrations: { status: 'ready', data: [] },
  now: NOW,
}

const vaultReady = (data: VaultAttention): AttentionInputs['vault'] => ({ status: 'ready', data })

describe('what needs attention', () => {
  it('is nothing when everything is fine', () => {
    expect(attentionGroups(quiet)).toEqual([])
    expect(isSettled(quiet)).toBe(true)
  })

  it('names a harness whose hook program is gone, and leaves what is not set up to the setup card', () => {
    const groups = attentionGroups({
      ...quiet,
      config: { status: 'ready', data: config(null) },
      vault: vaultReady({ configured: false }),
      integrations: {
        status: 'ready',
        data: [
          { harness: 'Claude', state: 'broken', hook: '/gone/synapse-hook', version: null },
          { harness: 'Codex', state: 'absent', hook: null, version: null },
        ] as Integration[],
      },
    })
    expect(groups.map((g) => g.key)).toEqual(['harnesses'])
    expect(groups[0]?.items.map((i) => [i.label, i.target])).toEqual([
      [
        'Claude Code names a hook program that is gone',
        { kind: 'settings', section: 'integrations' },
      ],
    ])
  })

  it('lists the runs that failed or were interrupted lately, newest first as given, and not older ones', () => {
    const groups = attentionGroups({
      ...quiet,
      runs: {
        status: 'ready',
        data: [
          run('a', 'failed', '2026-11-07T10:00:00Z', { failure: 'exit 1', failureStep: 'Build' }),
          run('b', 'interrupted', '2026-11-06T10:00:00Z'),
          run('c', 'completed', '2026-11-07T10:00:00Z'),
          run('d', 'failed', '2026-10-01T10:00:00Z'),
          run('e', 'running', '2026-11-08T11:00:00Z'),
          run('f', 'incomplete', null),
        ],
      },
    })
    const items = groups.find((g) => g.key === 'runs')?.items ?? []
    expect(items.map((i) => [i.label, i.detail, i.target])).toEqual([
      ['Ship failed', 'Build: exit 1', { kind: 'execution', id: 'a' }],
      ['Ship was interrupted', null, { kind: 'execution', id: 'b' }],
    ])
  })

  it('shows at most ten runs and says how many more there are', () => {
    const many = Array.from({ length: 13 }, (_, i) =>
      run(`r${i}`, 'failed', '2026-11-07T10:00:00Z'),
    )
    const items =
      attentionGroups({ ...quiet, runs: { status: 'ready', data: many } })[0]?.items ?? []
    expect(items).toHaveLength(11)
    expect(items.at(-1)?.label).toBe('and 3 more')
  })

  it("takes the vault's categories that have items, with their id, title and what they carry", () => {
    const groups = attentionGroups({
      ...quiet,
      vault: vaultReady({ configured: true, vault: '/v', categories: status.categories }),
    })
    expect(groups.map((g) => g.title)).toEqual([
      'Discussing',
      'Open questions',
      'In progress (unchecked items)',
    ])
    expect(groups[1]?.items.map((i) => [i.id, i.label, i.detail])).toEqual([
      ['p-2', 'Asks', 'Not compiled'],
      [null, 'Going', 'Compiled task: Going task'],
    ])
    expect(groups[2]?.items[0]).toMatchObject({ id: 'p-3', label: 'Work', detail: '4 unchecked' })
    expect(groups[0]?.items[0]?.target).toEqual({ kind: 'note', path: 'designs/a.md' })
    expect(groups[2]?.items[0]?.target).toEqual({ kind: 'note', path: 'tasks/t.md' })
  })

  it('puts harnesses before runs before the vault', () => {
    const groups = attentionGroups({
      ...quiet,
      integrations: {
        status: 'ready',
        data: [{ harness: 'Claude', state: 'broken', hook: '/x', version: null }] as Integration[],
      },
      runs: { status: 'ready', data: [run('a', 'failed', '2026-11-07T10:00:00Z')] },
      vault: vaultReady({ configured: true, vault: '/v', categories: status.categories }),
    })
    expect(groups.map((g) => g.key).slice(0, 3)).toEqual(['harnesses', 'runs', 'vault:discussing'])
  })

  it('says nothing of a source that is still loading, and names one that failed', () => {
    const inputs: AttentionInputs = {
      ...quiet,
      vault: { status: 'loading' },
      runs: { status: 'failed', error: 'no work directory' },
    }
    expect(attentionGroups(inputs)).toEqual([])
    expect(isSettled(inputs)).toBe(false)
    expect(attentionFailures(inputs)).toEqual([{ source: 'the runs', error: 'no work directory' }])
  })
})
