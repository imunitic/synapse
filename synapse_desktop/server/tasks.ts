// What a session of a harness is started to do: build a code graph, rebuild what
// changed in it, or rebuild it from scratch. The harness is given a plain sentence
// as its first prompt, as a person would type it, and finds the skill of Synapse
// that it names by the skill's description.

import type { TerminalKind, TerminalTask } from '../shared/transport.ts'

const SENTENCES: Record<TerminalTask, string> = {
  init: 'Do a synapse init.',
  'rebuild-diff': 'Do a synapse rebuild diff.',
  'rebuild-full': 'Do a synapse rebuild full.',
}

// The first prompt, the same for every harness; a shell has none.
export function taskPrompt(kind: TerminalKind, task: TerminalTask): string | null {
  return kind === 'Shell' ? null : SENTENCES[task]
}

// The arguments that give the harness its first prompt, which OpenCode takes as
// a flag and the others as the last argument.
export function taskArgs(kind: TerminalKind, task: TerminalTask): string[] {
  const prompt = taskPrompt(kind, task)
  if (prompt === null) return []
  return kind === 'Opencode' ? ['--prompt', prompt] : [prompt]
}
