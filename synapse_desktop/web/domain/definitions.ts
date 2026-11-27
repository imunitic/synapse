// The definitions there are: what `synapse-pipeline definitions` lists, which finds
// them the way every other command does.

import { z } from 'zod'
import type { Transport } from '../../shared/transport.ts'

export type DefinitionKind = 'pipeline' | 'system' | 'agent' | 'prompt'

export interface Definition {
  name: string
  kind: DefinitionKind
  path: string
  // The definition's `Description`; null when it has none.
  description: string | null
}

// A file that did not load, with where in it and what is wrong. A name claimed by two
// files is one of these, and then belongs to neither.
export interface LoadProblem {
  file: string
  line: number
  column: number
  message: string
}

export interface DefinitionListing {
  definitions: Definition[]
  problems: LoadProblem[]
}

const KINDS = new Map<string, DefinitionKind>([
  ['Pipeline', 'pipeline'],
  ['System', 'system'],
  ['Agent', 'agent'],
  ['Prompt', 'prompt'],
])

// The kind a file declares with its first word, after any comments (`--` to
// the end of the line); null when it does not start with one.
export function kindOfSource(text: string): DefinitionKind | null {
  const match = /^(?:\s|--[^\n]*)*([A-Za-z][A-Za-z0-9_]*)/.exec(text)
  return KINDS.get(match?.[1] ?? '') ?? null
}

function join(dir: string, name: string): string {
  return `${dir}/${name}`
}

// The definitions of one directory of a run's record, with the kind each declares. A file
// that does not start with a kind is left out. The record is a copy, so it is read as
// files, without their descriptions; the live definitions are found by the CLI.
async function readDefinitionDir(transport: Transport, dir: string): Promise<Definition[]> {
  const entries = await transport.readDir(dir)
  const files = entries.filter((e) => !e.isDir && e.name.endsWith('.synapse'))
  const found = await Promise.all(
    files.map(async (file) => {
      const path = join(dir, file.name)
      const kind = kindOfSource(await transport.readText(path))
      return kind === null
        ? null
        : { name: file.name.slice(0, -'.synapse'.length), kind, path, description: null }
    }),
  )
  return found.filter((d) => d !== null)
}

const listingSchema = z.object({
  format: z.literal('synapse-pipeline-definitions/v1'),
  definitions: z.array(
    z.object({
      kind: z.enum(['pipeline', 'system', 'agent', 'prompt']),
      name: z.string(),
      file: z.string(),
      description: z.string().nullable().optional(),
    }),
  ),
  problems: z.array(
    z.object({
      file: z.string(),
      line: z.number(),
      column: z.number(),
      message: z.string(),
    }),
  ),
})

// Every definition, by name, and every file that did not load. Throws when the CLI cannot
// be run or answers in a format this app does not know.
export async function loadDefinitions(transport: Transport): Promise<DefinitionListing> {
  const result = await transport.cli('synapse-pipeline', ['definitions', '--format', 'json'])
  if (result.code !== 0) {
    throw new Error((result.stderr || result.stdout).trim() || 'definitions could not run')
  }
  let json: unknown
  try {
    json = JSON.parse(result.stdout)
  } catch {
    throw new Error('definitions did not answer JSON')
  }
  const parsed = listingSchema.safeParse(json)
  if (!parsed.success) throw new Error('definitions answered a listing this app does not know')
  return {
    // By name the way a person reads a list, not by the byte order the CLI lists in.
    definitions: parsed.data.definitions
      .map((d) => ({
        name: d.name,
        kind: d.kind,
        path: d.file,
        description: d.description ?? null,
      }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    problems: parsed.data.problems,
  }
}

export async function listDefinitions(transport: Transport): Promise<Definition[]> {
  return (await loadDefinitions(transport)).definitions
}

export interface RecordedDefinitions {
  definitions: Definition[]
}

// The definition files a run's record keeps, laid out in it as a configuration
// directory is. A record made before it kept them has none.
export async function listRecordedDefinitions(
  transport: Transport,
  executionId: string,
): Promise<RecordedDefinitions> {
  const { recordsDir } = await transport.getPaths()
  if (recordsDir === null) return { definitions: [] }
  const dir = `${recordsDir}/${executionId}/definitions/synapse-pipeline`
  const definitions = await readDefinitionDir(transport, dir).catch(() => [])
  return { definitions: definitions.sort((a, b) => a.name.localeCompare(b.name)) }
}
