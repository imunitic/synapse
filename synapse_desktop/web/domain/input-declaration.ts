// What the Run dialog derives from a pipeline's `Input` declaration: the sample it starts the
// editor with, the reference of the fields shown under it, whether a plain sentence will do, and
// the problems `check --input` reports. Pure, so the dialog only has to show them.

import type { CliResult } from '../../shared/transport.ts'
import type { InputDeclaration, InputField } from './pipelines.ts'

// The empty value of a field's type: what the person fills in.
function emptyValue(type: string): unknown {
  switch (type) {
    case 'integer':
      return 0
    case 'boolean':
      return false
    case 'list':
      return []
    default:
      return ''
  }
}

// An object with every declared field, in declared order, each with an empty value of its type,
// as pretty JSON.
export function sampleInput(declared: InputDeclaration): string {
  const sample: Record<string, unknown> = {}
  for (const field of declared.fields) sample[field.name] = emptyValue(field.type)
  return JSON.stringify(sample, null, 2)
}

function typeLabel(field: InputField): string {
  if (field.type !== 'list') return field.type
  if (typeof field.items === 'string') return `list of ${field.items}`
  return 'list of items'
}

// One row per declared field, in declared order.
export function fieldReference(
  declared: InputDeclaration,
): { name: string; type: string; required: boolean; description: string }[] {
  return declared.fields.map((field) => ({
    name: field.name,
    type: typeLabel(field),
    required: field.required,
    description: field.description,
  }))
}

// Whether a plain sentence is an input the pipeline takes: any input when it declares none, or a
// declaration with one required string field the sentence fills.
export function takesText(declared: InputDeclaration | null): boolean {
  return declared === null || declared.single_text_field !== null
}

// The problems `check --input` reported, without their `error: ` prefix; none when it accepted
// the input. Warnings are not problems with the input. A check that failed without saying why still
// refused the input, so it gives what it wrote instead, or that the input could not be checked.
export function checkProblems(result: CliResult): string[] {
  if (result.code === 0) return []
  const errors = result.stderr
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.startsWith('error: '))
    .map((line) => line.slice('error: '.length))
  if (errors.length > 0) return errors
  const said = result.stderr.trim()
  return [said === '' ? 'The input could not be checked.' : said]
}
