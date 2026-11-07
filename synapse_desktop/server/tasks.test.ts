import { describe, expect, it } from 'vitest'
import { taskArgs, taskPrompt } from './tasks.ts'

describe('the first prompt of a task', () => {
  it('is a slash command for Claude Code and OpenCode and a named skill for Codex', () => {
    expect(taskPrompt('Claude', 'rebuild-diff')).toBe('/synapse-rebuild-diff')
    expect(taskPrompt('Opencode', 'rebuild-full')).toBe('/synapse-rebuild-full')
    expect(taskPrompt('Codex', 'rebuild-diff')).toBe('$synapse-rebuild-diff')
    expect(taskPrompt('Claude', 'init')).toBe('/synapse-init')
  })

  it('is none for a shell, which has no prompt to give', () => {
    expect(taskPrompt('Shell', 'init')).toBeNull()
    expect(taskArgs('Shell', 'rebuild-full')).toEqual([])
  })

  it('is the last argument, or after --prompt for OpenCode', () => {
    expect(taskArgs('Claude', 'rebuild-diff')).toEqual(['/synapse-rebuild-diff'])
    expect(taskArgs('Codex', 'rebuild-full')).toEqual(['$synapse-rebuild-full'])
    expect(taskArgs('Opencode', 'init')).toEqual(['--prompt', '/synapse-init'])
  })
})
