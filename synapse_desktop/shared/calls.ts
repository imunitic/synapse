// The parameters of each API call, validated at the server's boundary. The
// names are the Transport methods that travel over HTTP.

import { z } from 'zod'

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

export const callParams = {
  readText: z.object({ path: z.string() }),
  readDir: z.object({ path: z.string() }),
  cli: z.object({
    binary: z.enum(['synapse-pipeline', 'synapse']),
    args: z.array(z.string()),
    stdin: z.string().optional(),
  }),
  getConfig: z.object({}),
  setConfig: z.object({ patch: appConfigSchema.partial() }),
} as const

export type CallName = keyof typeof callParams

export function isCallName(name: string): name is CallName {
  return Object.hasOwn(callParams, name)
}
