import { describe, expect, it } from 'vitest'
import { taskArgs, taskPrompt } from './tasks.ts'

describe('the first prompt of a task', () => {
  it('is a plain sentence, the same for every harness', () => {
    for (const kind of ['Claude', 'Codex', 'Opencode'] as const) {
      expect(taskPrompt(kind, 'rebuild-diff')).toBe('Do a synapse rebuild diff.')
      expect(taskPrompt(kind, 'rebuild-full')).toBe('Do a synapse rebuild full.')
      expect(taskPrompt(kind, 'init')).toBe('Do a synapse init.')
    }
  })

  it('has no slash and no dollar, which only some harnesses read', () => {
    for (const task of ['init', 'rebuild-diff', 'rebuild-full'] as const) {
      expect(taskPrompt('Claude', task)).not.toMatch(/^[/$]/)
    }
  })

  it('is none for a shell, which has no prompt to give', () => {
    expect(taskPrompt('Shell', 'init')).toBeNull()
    expect(taskArgs('Shell', 'rebuild-full')).toEqual([])
  })

  it('is the last argument, or after --prompt for OpenCode', () => {
    expect(taskArgs('Claude', 'rebuild-diff')).toEqual(['Do a synapse rebuild diff.'])
    expect(taskArgs('Codex', 'rebuild-full')).toEqual(['Do a synapse rebuild full.'])
    expect(taskArgs('Opencode', 'init')).toEqual(['--prompt', 'Do a synapse init.'])
  })
})
