import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import {
  attributesFor,
  DSL_ATTRIBUTES,
  DSL_RULES,
  DSL_SHAPES,
  type DslKind,
} from '../web/domain/dsl-reference.ts'

const root = fileURLToPath(new URL('../../', import.meta.url))
const WHERE = '(?:pipeline|step|edge|system|agent|prompt)'

// Where each attribute may be written, the places of every row that names it together.
function add(table: Map<string, string[]>, name: string, where: string): void {
  table.set(name, [...(table.get(name) ?? []), ...where.split(', ')].sort())
}

// The attribute table in the comment of the language's own source, which is what is enforced. A
// row without a name, indented under the one before, is more places for that attribute.
function sourceTable(): Map<string, string[]> {
  const text = readFileSync(
    `${root}synapse_pipeline/src/language/syntax/synapse-pipeline-attributes.ads`,
    'utf8',
  )
  const table = new Map<string, string[]>()
  let last: string | null = null
  for (const line of text.split('\n')) {
    const row = new RegExp(
      `^--    ([A-Z][A-Za-z_]*)\\s{2,}(${WHERE}(?:, ${WHERE})*)(?:\\s|$)`,
    ).exec(line)
    const more = new RegExp(`^--\\s{21}(${WHERE}(?:, ${WHERE})*)\\s{2,}`).exec(line)
    if (row?.[1] !== undefined && row[2] !== undefined) {
      last = row[1]
      add(table, row[1], row[2])
    } else if (more?.[1] !== undefined && last !== null) add(table, last, more[1])
    else if (!line.startsWith('--   ')) last = null
  }
  return table
}

// The table of attributes in the documentation of the language.
function docTable(): Map<string, string[]> {
  const text = readFileSync(`${root}docs/synapse/synapse-pipeline-language.md`, 'utf8')
  const table = new Map<string, string[]>()
  for (const line of text.split('\n')) {
    const row = new RegExp(`^\\| \`([A-Z][A-Za-z_]*)\` \\| (${WHERE}(?:, ${WHERE})*) \\|`).exec(
      line,
    )
    if (row?.[1] !== undefined && row[2] !== undefined) add(table, row[1], row[2])
  }
  return table
}

const reference = new Map(DSL_ATTRIBUTES.map((a) => [a.name, [...a.on].sort()]))

describe('the language reference', () => {
  it('has the attributes of the language, and where each may be written', () => {
    const source = sourceTable()
    expect(source.size).toBeGreaterThanOrEqual(12)
    expect([...reference].sort()).toEqual([...source].sort())
  })

  it('agrees with the table of the documentation', () => {
    const doc = docTable()
    expect(doc.size).toBeGreaterThanOrEqual(12)
    expect([...reference].sort()).toEqual([...doc].sort())
  })

  it('gives each kind the attributes that are written on it', () => {
    const names = (kind: DslKind) => attributesFor(kind).map((a) => a.name)
    expect(names('agent').sort()).toEqual(['Description', 'Prompt'])
    expect(names('prompt').sort()).toEqual(['Description', 'Prompt'])
    expect(names('system')).toContain('Permissions')
    expect(names('system')).not.toContain('System')
    expect(names('pipeline')).toEqual(
      expect.arrayContaining(['Description', 'System', 'When', 'Max_Iterations']),
    )
  })

  it('has a shape and rules for each kind, and a shape that names its kind', () => {
    for (const kind of ['pipeline', 'system', 'agent', 'prompt'] as const) {
      expect(DSL_SHAPES[kind]).toContain(`${kind[0]!.toUpperCase()}${kind.slice(1)} Name [`)
      expect(DSL_RULES[kind].length).toBeGreaterThan(2)
    }
  })
})
