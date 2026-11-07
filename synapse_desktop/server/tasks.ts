// What a session of a harness is started to do: build a code graph, rebuild what
// changed in it, or rebuild it from scratch. Each is a command or skill of
// Synapse that the harness is given as its first prompt, in the way that harness
// takes one.

import type { TerminalKind, TerminalTask } from '../shared/transport.ts'

const COMMANDS: Record<TerminalTask, string> = {
  init: 'synapse-init',
  'rebuild-diff': 'synapse-rebuild-diff',
  'rebuild-full': 'synapse-rebuild-full',
}

// The first prompt: a slash command for Claude Code and OpenCode, which load
// Synapse's commands, and the skill named by `$` for Codex, which loads skills.
export function taskPrompt(kind: TerminalKind, task: TerminalTask): string | null {
  switch (kind) {
    case 'Claude':
    case 'Opencode':
      return `/${COMMANDS[task]}`
    case 'Codex':
      return `$${COMMANDS[task]}`
    case 'Shell':
      return null
  }
}

// The arguments that give the harness its first prompt, which OpenCode takes as
// a flag and the others as the last argument.
export function taskArgs(kind: TerminalKind, task: TerminalTask): string[] {
  const prompt = taskPrompt(kind, task)
  if (prompt === null) return []
  return kind === 'Opencode' ? ['--prompt', prompt] : [prompt]
}
