// The efforts each harness offers, which the server and the page both check an effort against.

import { z } from 'zod'
import type { Harness } from './transport.ts'

// Claude's `--effort` values.
export const CLAUDE_EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'] as const
// Codex's `model_reasoning_effort` values: the names its `ReasoningEffort` enum knows.
export const CODEX_EFFORTS = [
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
  'ultra',
  'persistent',
] as const
// An OpenCode variant: named by the model, so any name of this shape. It starts with a letter or
// a digit, so that it cannot be taken for a flag, and holds no `#`, which separates it from the
// model.
export const VARIANT_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/

// The efforts a harness offers, in order; null for OpenCode, whose variant is typed.
export function effortsOf(harness: Harness): readonly string[] | null {
  switch (harness) {
    case 'Claude':
      return CLAUDE_EFFORTS
    case 'Codex':
      return CODEX_EFFORTS
    case 'Opencode':
      return null
  }
}

// Whether the harness takes this effort.
export function isEffortFor(harness: Harness, effort: string): boolean {
  const efforts = effortsOf(harness)
  return efforts === null ? VARIANT_NAME.test(effort) : efforts.includes(effort)
}

// An effort as the host is sent it: a variant's shape, which every list value also has.
export const effortSchema = z.string().regex(VARIANT_NAME)
