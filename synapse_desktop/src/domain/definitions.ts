// The definitions on disk: .synapse files holding a Pipeline, a System or an
// Agent, and the skill directories.

import type { Transport } from '../../shared/transport.ts'

export type DefinitionKind = 'pipeline' | 'system' | 'agent'

export interface Definition {
  name: string
  kind: DefinitionKind
  path: string
  // A name claimed by two files belongs to neither.
  duplicate: boolean
}

export interface Skill {
  name: string
  // The skill's SKILL.md.
  path: string
}

const KINDS = new Map<string, DefinitionKind>([
  ['Pipeline', 'pipeline'],
  ['System', 'system'],
  ['Agent', 'agent'],
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

// Every definition in the definition directories, by name. A file that does
// not start with a kind is left out.
export async function listDefinitions(transport: Transport): Promise<Definition[]> {
  const { definitionDirs } = await transport.getPaths()
  const perDirectory = await Promise.all(
    definitionDirs.map(async (dir) => {
      const entries = await transport.readDir(dir)
      const files = entries.filter((e) => !e.isDir && e.name.endsWith('.synapse'))
      const found = await Promise.all(
        files.map(async (file) => {
          const path = join(dir, file.name)
          const kind = kindOfSource(await transport.readText(path))
          return kind === null
            ? null
            : { name: file.name.slice(0, -'.synapse'.length), kind, path, duplicate: false }
        }),
      )
      return found.filter((d) => d !== null)
    }),
  )
  const all = perDirectory.flat()
  const counts = new Map<string, number>()
  for (const d of all) counts.set(d.name, (counts.get(d.name) ?? 0) + 1)
  return all
    .map((d) => ({ ...d, duplicate: (counts.get(d.name) ?? 0) > 1 }))
    .sort((a, b) => a.name.localeCompare(b.name))
}

// The directories of the skills directory that hold a SKILL.md.
export async function listSkills(transport: Transport): Promise<Skill[]> {
  const { skillsDir } = await transport.getPaths()
  if (skillsDir === null) return []
  const entries = await transport.readDir(skillsDir)
  const found = await Promise.all(
    entries
      .filter((e) => e.isDir)
      .map(async (dir) => {
        const inside = await transport.readDir(join(skillsDir, dir.name))
        return inside.some((e) => !e.isDir && e.name === 'SKILL.md')
          ? { name: dir.name, path: join(join(skillsDir, dir.name), 'SKILL.md') }
          : null
      }),
  )
  return found.filter((s) => s !== null).sort((a, b) => a.name.localeCompare(b.name))
}
