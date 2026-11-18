// What a skill's directory holds.

import type { Transport } from '../../shared/transport.ts'

export interface SkillMeta {
  name: string | null
  description: string | null
}

// The `name` and `description` of the frontmatter at the top of a SKILL.md: a
// block between two lines of `---`, with one `key: value` to a line. A value in
// quotes loses them; anything the block does not give is null.
export function parseSkillMeta(text: string): SkillMeta {
  const lines = text.split('\n')
  const meta: SkillMeta = { name: null, description: null }
  if (lines[0]?.trim() !== '---') return meta
  for (const line of lines.slice(1)) {
    if (line.trim() === '---') break
    const match = /^(name|description):\s*(.*)$/.exec(line)
    if (match?.[1] !== undefined && match[2] !== undefined) {
      const value = match[2].trim().replace(/^(['"])(.*)\1$/, '$2')
      meta[match[1] as 'name' | 'description'] = value === '' ? null : value
    }
  }
  return meta
}

// The names of what is in the skill's directory, directories marked with a slash.
export async function listSkillFiles(transport: Transport, skillFile: string): Promise<string[]> {
  const dir = skillFile.slice(0, skillFile.lastIndexOf('/'))
  const entries = await transport.readDir(dir)
  return entries.map((e) => (e.isDir ? `${e.name}/` : e.name)).sort((a, b) => a.localeCompare(b))
}
