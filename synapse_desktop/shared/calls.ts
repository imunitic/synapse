// The parameters of each API call, validated at the server's boundary. The
// names are the Transport methods that travel over HTTP.

import { z } from 'zod'
import type { RunRequest } from './transport.ts'

// `<repo>@<branch>`: a folder's name, with no separator and no dots alone.
export const namespaceSchema = z.string().regex(/^[A-Za-z0-9._+-]{1,128}@[A-Za-z0-9._+-]{1,128}$/)

export const harnessSchema = z.enum(['Claude', 'Codex', 'Opencode'])

// A variable's name: the form every shell takes.
export const envNameSchema = z
  .string()
  .regex(/^[A-Za-z_][A-Za-z0-9_]*$/)
  .max(128)

const configFields = {
  workDir: z.string().min(1).nullable(),
  definitionPaths: z.array(z.string().min(1)),
  defaultHarness: harnessSchema.nullable(),
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
  graphRepos: configFields.graphRepos.default({}),
})

export const defaultConfig: z.infer<typeof appConfigSchema> = {
  workDir: null,
  definitionPaths: [],
  defaultHarness: null,
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

const draftText = z.string().max(200_000)

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
  previewDraft: z.object({
    draft: z.object({
      kind: z.enum(['pipeline', 'system', 'agent']),
      name: definitionNameSchema,
      text: draftText,
    }),
  }),
  writeDefinition: z.union([
    z.object({ kind: z.literal('definition'), name: definitionNameSchema, text: draftText }),
    z.object({ kind: z.literal('skill'), name: skillNameSchema, text: draftText }),
  ]),
  saveDefinition: z.object({ path: z.string(), previous: draftText, text: draftText }),
  generateDefinition: z.object({
    kind: z.enum(['pipeline', 'system', 'agent', 'skill']),
    prompt: z.string().min(1).max(20_000),
    harness: harnessSchema.optional(),
    current: draftText.optional(),
    definitions: z
      .array(
        z.object({ name: definitionNameSchema, kind: z.enum(['pipeline', 'system', 'agent']) }),
      )
      .max(1000),
    skills: z.array(skillNameSchema).max(1000),
  }),
  inspectVault: z.object({ path: z.string().min(1).max(4096) }),
  getIntegrations: z.object({}),
  configureHarness: z.object({ harness: harnessSchema }),
  checkGraphRepo: z.object({ path: z.string().min(1).max(4096) }),
  graphHealth: z.object({ namespace: namespaceSchema }),
  planGraphDrop: z.object({ namespace: namespaceSchema }),
  dropGraph: z.object({ namespace: namespaceSchema }),
  planGraphClean: z.object({ namespace: namespaceSchema }),
  cleanGraphs: z.object({ namespace: namespaceSchema }),
  getConfig: z.object({}),
  getPaths: z.object({}),
  setConfig: z.object({ patch: appConfigSchema.partial() }),
} as const

export type CallName = keyof typeof callParams

export function isCallName(name: string): name is CallName {
  return Object.hasOwn(callParams, name)
}
