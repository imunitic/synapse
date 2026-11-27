// Describing a pipeline: what `synapse-pipeline show --format json` answers, or
// the problems it reports when the pipeline cannot run.

import { z } from 'zod'
import type { CliResult, Transport } from '../../shared/transport.ts'

// `role` and `assignment`: the text, whether written inline or taken from a Prompt definition.
const instructionSchema = z.object({ kind: z.literal('prompt'), text: z.string() }).nullable()

export type Instruction = z.infer<typeof instructionSchema>

// A definition a step is built from: its system, its agent and the prompts it names.
const originSchema = z.object({
  kind: z.enum(['system', 'agent', 'prompt']),
  name: z.string(),
  file: z.string(),
})

// One field of a pipeline's `Input` or a step's `Data`: its rules as written. A list's `items`
// is a type name, or fields of the same shape.
export interface InputField {
  name: string
  type: string
  required: boolean
  description: string
  min_length?: number | undefined
  const?: unknown
  pattern?: string | undefined
  enum?: unknown[] | undefined
  items?: string | { fields: InputField[] } | undefined
}

const inputFieldSchema: z.ZodType<InputField> = z.lazy(() =>
  z.object({
    name: z.string(),
    type: z.string(),
    required: z.boolean(),
    description: z.string(),
    min_length: z.number().optional(),
    const: z.unknown().optional(),
    pattern: z.string().optional(),
    enum: z.array(z.unknown()).optional(),
    items: z.union([z.string(), z.object({ fields: z.array(inputFieldSchema) })]).optional(),
  }),
)

// What a step may end with: the word guards test, what it means, and the fields its result's
// `data` holds with that word, or null when the outcome declares none.
const outcomeSchema = z.object({
  word: z.string(),
  meaning: z.string(),
  data: z.array(inputFieldSchema).nullable().default(null),
})

export type StepOutcome = z.infer<typeof outcomeSchema>

// The fields a step's result holds in `data`, whatever its outcome.
const dataDeclarationSchema = z.object({
  fields: z.array(inputFieldSchema),
  checks: z.array(z.unknown()),
})

export type DataDeclaration = z.infer<typeof dataDeclarationSchema>

const stepSchema = z.object({
  name: z.string(),
  harness: z.string(),
  model: z.string().nullable(),
  permissions: z.string(),
  timeout_seconds: z.number(),
  retries: z.number(),
  // Null when the step declares no `Data` and its result's data is not checked.
  data: dataDeclarationSchema.nullable().default(null),
  // Null when the step declares none and may end with any word.
  outcomes: z.array(outcomeSchema).nullable().default(null),
  role: instructionSchema,
  assignment: instructionSchema,
  origins: z.array(originSchema),
})

const edgeSchema = z.object({
  index: z.number(),
  from: z.string(),
  // A step's name, or End.
  to: z.string(),
  // A JsonLogic rule over the step's result; null when the edge is unconditional.
  guard: z.unknown(),
  max_iterations: z.number().nullable(),
})

// What a pipeline declares it is started with. `single_text_field` is the field a plain
// sentence fills, or null when the input must be JSON.
const inputDeclarationSchema = z.object({
  fields: z.array(inputFieldSchema),
  checks: z.array(z.unknown()),
  single_text_field: z.string().nullable(),
})

export type InputDeclaration = z.infer<typeof inputDeclarationSchema>

const descriptionSchema = z.object({
  format: z.literal('synapse-pipeline-description/v1'),
  name: z.string(),
  // Null when the pipeline declares no `Input` and takes any JSON value.
  input: inputDeclarationSchema.nullable().default(null),
  steps: z.array(stepSchema),
  edges: z.array(edgeSchema),
  limits: z.object({
    default_timeout_seconds: z.number(),
    step_ceiling: z.number(),
    runner: z.string(),
  }),
})

export type PipelineDescription = z.infer<typeof descriptionSchema>
export type PipelineStep = PipelineDescription['steps'][number]
export type PipelineEdge = PipelineDescription['edges'][number]

// The description a document holds, or null when it is not one this app knows.
export function parseDescription(json: unknown): PipelineDescription | null {
  const parsed = descriptionSchema.safeParse(json)
  return parsed.success ? parsed.data : null
}

export interface Problem {
  severity: 'error' | 'warning'
  file: string | null
  line: number | null
  column: number | null
  message: string
}

// The problems the CLI printed, one per line: `error: <file>:<line>:<column>:
// <message>`. A line of another shape is kept whole as a message.
export function parseProblems(text: string): Problem[] {
  const problems: Problem[] = []
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line === '') continue
    const severity = line.startsWith('warning:') ? 'warning' : 'error'
    const body = line.replace(/^(error|warning):\s*/, '')
    const located = /^(.*?):(\d+):(\d+): (.*)$/.exec(body)
    problems.push(
      located
        ? {
            severity,
            file: located[1] ?? null,
            line: Number(located[2]),
            column: Number(located[3]),
            message: located[4] ?? '',
          }
        : { severity, file: null, line: null, column: null, message: body },
    )
  }
  return problems
}

// The outcome a guard tests, for the usual `outcome == Done`; null for any
// other rule and for no guard.
export function outcomeOf(guard: unknown): string | null {
  const parsed = z
    .object({ '==': z.tuple([z.object({ var: z.literal('outcome') }), z.string()]) })
    .safeParse(guard)
  return parsed.success ? parsed.data['=='][1] : null
}

// A guard as a short label: `Done` for the usual `outcome == Done`, else the
// rule as compact JSON; null for no guard.
export function guardLabel(guard: unknown): string | null {
  if (guard === null || guard === undefined) return null
  return outcomeOf(guard) ?? JSON.stringify(guard)
}

export type Described =
  { ok: true; description: PipelineDescription } | { ok: false; problems: Problem[] }

// What `show --format json` answered: the pipeline, or why it cannot run.
// Throws when the answer is in a format this app does not know.
export function readShown(result: CliResult): Described {
  if (result.code !== 0) {
    const problems = parseProblems(result.stderr)
    return {
      ok: false,
      problems:
        problems.length > 0
          ? problems
          : [{ severity: 'error', file: null, line: null, column: null, message: 'show failed' }],
    }
  }
  let json: unknown
  try {
    json = JSON.parse(result.stdout)
  } catch {
    throw new Error('show did not answer JSON')
  }
  const description = parseDescription(json)
  if (description === null) throw new Error('show answered a description this app does not know')
  return { ok: true, description }
}

// The pipeline as the CLI resolves it, or why it cannot run. Throws when the
// CLI cannot be run or answers in a format this app does not know.
export async function describePipeline(transport: Transport, name: string): Promise<Described> {
  return readShown(await transport.cli('synapse-pipeline', ['show', name, '--format', 'json']))
}

// A prompt is made of parts: what the author wrote (the role and the assignment) and what the
// program adds to every step.
const partSchema = z.object({
  kind: z.enum(['role', 'assignment', 'protocol', 'input', 'previous', 'contract']),
  authored: z.boolean(),
  text: z.string(),
})

export type PromptPart = z.infer<typeof partSchema>

const promptSchema = z.object({
  format: z.literal('synapse-pipeline-prompt/v1'),
  pipeline: z.string(),
  step: z.string(),
  prompt: z.string(),
  parts: z.array(partSchema),
})

export type StepPrompt =
  { ok: true; prompt: string; parts: PromptPart[] } | { ok: false; message: string }

// What the author wrote of a prompt, and what the program added, each as the text it makes.
export function splitPrompt(parts: readonly PromptPart[]): { authored: string; added: string } {
  const join = (wanted: boolean) =>
    parts
      .filter((p) => p.authored === wanted)
      .map((p) => p.text)
      .join('\n\n')
  return { authored: join(true), added: join(false) }
}

// The prompt a step is started with, as `show --step` builds it: the same text the
// runner hands the session. A step after the first has a marked slot for what the step
// before reports. `input` is the JSON the run is started with, when there is one. The
// message is the CLI's when it cannot say, such as for an input that is not JSON.
// Throws when the CLI cannot be run or answers in a format this app does not know.
export async function describeStepPrompt(
  transport: Transport,
  pipeline: string,
  step: string,
  input?: string,
  // The prompt of a step that runs on a terminal, where a person can answer.
  interactive = false,
): Promise<StepPrompt> {
  const args = ['show', pipeline, '--step', step, '--format', 'json']
  if (input !== undefined) args.push('--input', '-')
  if (interactive) args.push('--interactive')
  const result = await transport.cli(
    'synapse-pipeline',
    args,
    input === undefined ? undefined : { stdin: input },
  )
  if (result.code !== 0) {
    const message = result.stderr
      .split('\n')
      .map((line) => line.replace(/^error:\s*/, '').trim())
      .filter((line) => line !== '')
      .join(' ')
    return { ok: false, message: message === '' ? 'show failed' : message }
  }
  let json: unknown
  try {
    json = JSON.parse(result.stdout)
  } catch {
    throw new Error('show did not answer JSON')
  }
  const parsed = promptSchema.safeParse(json)
  if (!parsed.success) throw new Error('show answered a prompt this app does not know')
  return { ok: true, prompt: parsed.data.prompt, parts: parsed.data.parts }
}
