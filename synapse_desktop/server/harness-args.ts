// The arguments that ask a harness for a model and an effort, for every headless session the
// server starts.

import type { Harness } from '../shared/transport.ts'

// The arguments that ask a harness for a model and an effort: Claude `--model M --effort E`,
// Codex `-m M -c model_reasoning_effort="E"`, OpenCode `-m M#E`. Nothing for what is absent.
// OpenCode takes the variant only as part of a model, so an effort without one adds nothing;
// the caller refuses that case before it gets here.
export function modelArgs(harness: Harness, model?: string, effort?: string): string[] {
  switch (harness) {
    case 'Claude':
      return [
        ...(model === undefined ? [] : ['--model', model]),
        ...(effort === undefined ? [] : ['--effort', effort]),
      ]
    case 'Codex':
      return [
        ...(model === undefined ? [] : ['-m', model]),
        ...(effort === undefined ? [] : ['-c', `model_reasoning_effort="${effort}"`]),
      ]
    case 'Opencode':
      if (model === undefined) return []
      return ['-m', effort === undefined ? model : `${model}#${effort}`]
  }
}
