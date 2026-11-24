import { describe, expect, it } from 'vitest'
import type { Action, ActionKind, Activity } from './activity.ts'
import { activityOfRun, claudeLines, formatElapsed, latestAction } from './note-run.ts'

const line = (event: unknown) => JSON.stringify(event)

const init = line({ type: 'system', subtype: 'init', tools: [] })
const toolUse = line({
  type: 'assistant',
  message: {
    content: [
      {
        type: 'tool_use',
        id: 't1',
        name: 'Bash',
        input: { command: 'synapse vault-read research/Target.md' },
      },
    ],
  },
})
const toolResult = line({
  type: 'user',
  message: { content: [{ type: 'tool_result', tool_use_id: 't1', content: 'body' }] },
})
const text = line({
  type: 'assistant',
  message: { content: [{ type: 'text', text: 'I changed the note.' }] },
})
const result = line({ type: 'result', subtype: 'success', result: 'EDITED' })

const activityOf = (kind: ActionKind, target: string | null): Activity => {
  const action: Action = { kind, title: '', target, detail: null, status: 'ok' }
  return {
    harness: 'Claude',
    actions: [action],
    changes: [],
    stats: { costUsd: null, inputTokens: null, outputTokens: null, turns: null, durationMs: null },
  }
}

describe('formatElapsed', () => {
  it('shows minutes and seconds under an hour', () => {
    expect(formatElapsed(0)).toBe('0:00')
    expect(formatElapsed(42_000)).toBe('0:42')
    expect(formatElapsed(12 * 60_000 + 5_000)).toBe('12:05')
    expect(formatElapsed(59 * 60_000 + 59_000)).toBe('59:59')
  })

  it('shows hours from an hour', () => {
    expect(formatElapsed(3_600_000 + 2 * 60_000 + 3_000)).toBe('1:02:03')
  })

  it('does not go below zero', () => {
    expect(formatElapsed(-500)).toBe('0:00')
  })
})

describe('claudeLines', () => {
  it('keeps the messages and drops system and result lines', () => {
    const kept = claudeLines([init, toolUse, toolResult, text, result])
    expect(kept.split('\n')).toEqual([toolUse, toolResult, text])
  })

  it('drops lines that are not JSON', () => {
    expect(claudeLines(['not json', '', '{"type":', '[1,2]', 'null'])).toBe('')
  })

  it('reads as a Claude transcript', () => {
    const activity = activityOfRun([init, toolUse, toolResult, text, result])
    expect(activity.harness).toBe('Claude')
    expect(activity.actions.map((a) => a.kind)).toEqual(['command', 'message'])
    expect(activity.actions[0]).toMatchObject({
      target: 'synapse vault-read research/Target.md',
      status: 'ok',
    })
  })

  it('gives no actions for garbage', () => {
    expect(activityOfRun(['garbage', '{}']).actions).toEqual([])
  })
})

describe('latestAction', () => {
  it('names each kind', () => {
    expect(latestAction(activityOf('read', '/w/notes/Target.md'))).toBe('Reading Target.md')
    expect(latestAction(activityOf('write', 'a/b.md'))).toBe('Writing b.md')
    expect(latestAction(activityOf('edit', 'Target.md'))).toBe('Editing Target.md')
    expect(latestAction(activityOf('command', 'ls -la'))).toBe('Running ls -la')
    expect(latestAction(activityOf('search', 'todo'))).toBe('Searching todo')
    expect(latestAction(activityOf('message', null))).toBe('Writing a reply')
    expect(latestAction(activityOf('thinking', null))).toBe('Thinking')
    expect(latestAction(activityOf('other', null))).toBe('Working')
    expect(latestAction(activityOf('error', null))).toBe('Working')
  })

  it('cuts a long command to 60 characters', () => {
    const command = 'x'.repeat(100)
    expect(latestAction(activityOf('command', command))).toBe(`Running ${'x'.repeat(60)}…`)
  })

  it('does not cut a command of exactly 60 characters', () => {
    const command = 'y'.repeat(60)
    expect(latestAction(activityOf('command', command))).toBe(`Running ${command}`)
  })

  it('is null with no actions', () => {
    expect(latestAction({ ...activityOf('read', 'a'), actions: [] })).toBeNull()
  })

  it('reads the newest action of a run', () => {
    expect(latestAction(activityOfRun([init, toolUse]))).toBe(
      'Running synapse vault-read research/Target.md',
    )
  })
})
