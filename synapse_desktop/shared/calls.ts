// The parameters of each API call, validated at the server's boundary. The
// names are the Transport methods that travel over HTTP.

import { z } from 'zod'
import type { RunRequest } from './transport.ts'

export const harnessSchema = z.enum(['Claude', 'Codex', 'Opencode'])

export const appConfigSchema = z.object({
  workDir: z.string().min(1).nullable(),
  definitionPaths: z.array(z.string().min(1)),
  defaultHarness: harnessSchema.nullable(),
})

export const defaultConfig: z.infer<typeof appConfigSchema> = {
  workDir: null,
  definitionPaths: [],
  defaultHarness: null,
}

// A run's id names a directory, so it may not hold a separator or a dot.
export const executionIdSchema = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/)

export const runRequestSchema: z.ZodType<RunRequest> = z.discriminatedUnion('command', [
  z.object({ command: z.literal('info') }),
  z.object({ command: z.literal('state') }),
  z.object({ command: z.literal('pipeline') }),
  z.object({ command: z.literal('events'), after: z.number().int().nonnegative().optional() }),
  z.object({ command: z.literal('query'), expression: z.unknown() }),
])

export const callParams = {
  readText: z.object({ path: z.string() }),
  readDir: z.object({ path: z.string() }),
  cli: z.object({
    binary: z.enum(['synapse-pipeline', 'synapse']),
    args: z.array(z.string()),
    stdin: z.string().optional(),
  }),
  runRequest: z.object({ executionId: executionIdSchema, request: runRequestSchema }),
  startRun: z.object({
    // A definition's name is an identifier.
    pipeline: z.string().regex(/^[A-Za-z][A-Za-z0-9_]*$/),
    input: z.unknown(),
  }),
  stopRun: z.object({ executionId: executionIdSchema }),
  getConfig: z.object({}),
  getPaths: z.object({}),
  setConfig: z.object({ patch: appConfigSchema.partial() }),
} as const

export type CallName = keyof typeof callParams

export function isCallName(name: string): name is CallName {
  return Object.hasOwn(callParams, name)
}
