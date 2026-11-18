// The values the parameters of the messages are made of, validated at the host's boundary.

import { z } from 'zod'
import { MODEL_NAME } from './models.ts'
import type { RunRequest } from './transport.ts'

// `<repo>@<branch>`: a folder's name, with no separator and no dots alone.
export const namespaceSchema = z.string().regex(/^[A-Za-z0-9._+-]{1,128}@[A-Za-z0-9._+-]{1,128}$/)

export const harnessSchema = z.enum(['Claude', 'Codex', 'Opencode'])

// A variable's name: the form every shell takes.
export const envNameSchema = z
  .string()
  .regex(/^[A-Za-z_][A-Za-z0-9_]*$/)
  .max(128)

// A model as a harness is given it on its command line.
export const modelSchema = z.string().regex(MODEL_NAME)

const configFields = {
  workDir: z.string().min(1).nullable(),
  definitionPaths: z.array(z.string().min(1)),
  defaultHarness: harnessSchema.nullable(),
  // The model each harness is asked to use when nothing says another; none is its own default.
  defaultModels: z.partialRecord(harnessSchema, modelSchema),
  env: z
    .record(envNameSchema, z.string().max(4096))
    .refine((env) => Object.keys(env).length <= 64, 'at most 64 variables'),
  recentVaults: z.array(z.string().min(1)).max(8),
  terminalFolder: z.string().min(1).max(4096).nullable(),
  graphRepos: z
    .record(namespaceSchema, z.string().min(1).max(4096))
    .refine((repos) => Object.keys(repos).length <= 64, 'at most 64 repositories'),
}

export const appConfigSchema = z.object(configFields)

// The file as it is read: one written before a setting existed has its default.
export const storedConfigSchema = z.object({
  ...configFields,
  env: configFields.env.default({}),
  recentVaults: configFields.recentVaults.default([]),
  terminalFolder: configFields.terminalFolder.default(null),
  defaultModels: configFields.defaultModels.default({}),
  graphRepos: configFields.graphRepos.default({}),
})

export const defaultConfig: z.infer<typeof appConfigSchema> = {
  workDir: null,
  definitionPaths: [],
  defaultHarness: null,
  defaultModels: {},
  env: {},
  recentVaults: [],
  terminalFolder: null,
  graphRepos: {},
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

// A definition's name is its file's name: an identifier.
export const definitionNameSchema = z
  .string()
  .regex(/^[A-Za-z][A-Za-z0-9_]*$/)
  .max(128)

// The form the Agent Skills specification gives a skill's name.
export const skillNameSchema = z
  .string()
  .regex(/^[a-z0-9]+(-[a-z0-9]+)*$/)
  .max(64)
