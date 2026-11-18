import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import {
  attributesFor,
  DSL_ATTRIBUTES,
  DSL_RULES,
  DSL_SHAPES,
} from '../web/domain/dsl-reference.ts'

const root = fileURLToPath(new URL('../../', import.meta.url))
const WHERE = '(?:step|edge|system|agent)'

// The attribute table in the comment of the language's own source, which is what is enforced.
function sourceTable(): Map<string, string[]> {
  const text = readFileSync(
    `${root}synapse_pipeline/src/language/syntax/synapse-pipeline-attributes.ads`,
    'utf8',
  )
  const table = new Map<string, string[]>()
  for (const line of text.split('\n')) {
    const row = new RegExp(
      `^--    ([A-Z][A-Za-z_]*)\\s{2,}(${WHERE}(?:, ${WHERE})*)(?:\\s|$)`,
    ).exec(line)
    if (row?.[1] !== undefined && row[2] !== undefined) table.set(row[1], row[2].split(', ').sort())
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
    if (row?.[1] !== undefined && row[2] !== undefined) table.set(row[1], row[2].split(', ').sort())
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
    const names = (kind: 'pipeline' | 'system' | 'agent') => attributesFor(kind).map((a) => a.name)
    expect(names('agent')).toEqual(['Prompt', 'Skill'])
    expect(names('system')).toContain('Permissions')
    expect(names('system')).not.toContain('System')
    expect(names('pipeline')).toEqual(expect.arrayContaining(['System', 'When', 'Max_Iterations']))
  })

  it('has a shape and rules for each kind, and a shape that names its kind', () => {
    for (const kind of ['pipeline', 'system', 'agent'] as const) {
      expect(DSL_SHAPES[kind]).toContain(
        kind === 'pipeline'
          ? 'Pipeline Name {'
          : `${kind[0]!.toUpperCase()}${kind.slice(1)} Name [`,
      )
      expect(DSL_RULES[kind].length).toBeGreaterThan(2)
    }
  })
})
