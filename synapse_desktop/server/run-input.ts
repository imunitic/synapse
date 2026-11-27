// Having an agent write the input of a run from a description. The agent reads the
// pipeline's declaration, may look up notes in the vault to turn a description of one into
// its name, and answers with one JSON object. It writes nothing and never starts the run:
// the JSON goes into the run dialog's editor, where the person starts the run.

import { HostError } from '../shared/dispatch.ts'
import type { AppConfig, CliResult, Harness } from '../shared/transport.ts'
import type { CliRunner } from './cli.ts'
import { reasonOf } from './note-agent.ts'

// How the agent may reach the vault: only through the commands that read and search it.
const VAULT_RULE =
  'To turn a description of a note into its name, use only `synapse vault-search-text <words>`, `synapse vault-list` and `synapse vault-read <path>`. Write nothing.'

// Claude Code and OpenCode run a command only when the whole of it is allowed, so the
// session is told how to run them. Codex runs in its read-only sandbox.
const READ_COMMAND_RULES =
  'Only these three commands work in this session. Run one command in each Bash call: do not chain commands with ;, && or ||, do not pipe them, and do not use cd or echo.'

const CLOSING =
  'Answer with one JSON object that satisfies the declaration, and nothing else: no prose, no code fence.'

// The empty value of a field: what the run dialog's sample starts each field with.
function isEmptyValue(value: unknown): boolean {
  return (
    value === '' ||
    value === 0 ||
    value === false ||
    value === null ||
    (Array.isArray(value) && value.length === 0)
  )
}

// Whether the JSON in the editor says something the agent should keep: not when it is
// missing, `{}`, the sample with every field empty, or not an object at all.
function saysSomething(current: string | undefined): current is string {
  if (current === undefined) return false
  try {
    const parsed: unknown = JSON.parse(current)
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return false
    return !Object.values(parsed).every(isEmptyValue)
  } catch {
    // Text that is not JSON yet is still what the person typed.
    return current.trim() !== ''
  }
}

export function runInputPrompt(
  pipeline: string,
  declaration: unknown,
  description: string,
  current: string | undefined,
  harness: Harness,
  problems: readonly string[] = [],
): string {
  return [
    `Fill in the input of the pipeline ${pipeline} from the description below. Nobody can answer questions in this session, so decide what you would otherwise ask and carry on.`,
    '',
    'The pipeline declares its input as follows:',
    JSON.stringify(declaration, null, 2),
    '',
    ...(saysSomething(current)
      ? [
          'The input holds this JSON now: add to this; keep what the description does not change.',
          current.trim(),
          '',
        ]
      : []),
    VAULT_RULE,
    '',
    ...(harness === 'Codex' ? [] : [READ_COMMAND_RULES, '']),
    'Description:',
    description.trim(),
    '',
    ...(problems.length === 0
      ? []
      : ['These problems were found in your answer:', ...problems, '']),
    CLOSING,
  ].join('\n')
}

// The text of the JSON object in an answer, pretty-printed with a two-space indent: the
// answer without one surrounding code fence, from its first `{` to its last `}`. Nothing
// when that is not a JSON object, or when the answer is a list.
export function jsonAnswer(answer: string): string | null {
  let text = answer.trim()
  const fenced = /^```[^\n]*\n([\s\S]*?)\n?```$/.exec(text)
  if (fenced !== null) text = (fenced[1] ?? '').trim()
  // A list of objects is not one object, though its first `{` and last `}` may make one.
  if (text.startsWith('[')) return null
  const start = text.indexOf('{')
  const end = text.lastIndexOf('}')
  if (start === -1 || end < start) return null
  try {
    const parsed: unknown = JSON.parse(text.slice(start, end + 1))
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return null
    return JSON.stringify(parsed, null, 2)
  } catch {
    return null
  }
}

// What filling in the input of a run takes: the program, the configuration it runs with, the
// harness the prompt is written for, a read session given the prompt, and whether the run was
// stopped.
export interface RunInputDeps {
  run: CliRunner
  config: AppConfig
  harness: Harness
  session: (prompt: string) => Promise<CliResult>
  stopped?: () => boolean
}

export interface RunInputAsk {
  pipeline: string
  prompt: string
  current?: string | undefined
}

// The declared input of a pipeline, from `synapse-pipeline show <pipeline> --format json`; null
// when the pipeline declares none.
async function declarationOf(pipeline: string, deps: RunInputDeps): Promise<unknown> {
  const shown = await deps.run({
    binary: 'synapse-pipeline',
    args: ['show', pipeline, '--format', 'json'],
    config: deps.config,
  })
  if (shown.code !== 0) {
    const why = shown.stderr.trim() || `${pipeline} could not be read`
    throw new HostError(/there is no pipeline named/.test(why) ? 'not_found' : 'unavailable', why)
  }
  try {
    const parsed = JSON.parse(shown.stdout) as { input?: unknown }
    return parsed.input ?? null
  } catch {
    throw new HostError('unavailable', `the description of ${pipeline} is not JSON`)
  }
}

// The JSON an agent wrote for the input of a run, from a description of the run: checked by the
// program, with one more session to correct it when the program found problems. Never run.
export async function fillRunInput(ask: RunInputAsk, deps: RunInputDeps): Promise<string> {
  const declaration = await declarationOf(ask.pipeline, deps)
  if (declaration === null) {
    throw new HostError('conflict', `${ask.pipeline} declares no input`)
  }
  const prompt = (current: string | undefined, problems: readonly string[] = []) =>
    runInputPrompt(ask.pipeline, declaration, ask.prompt, current, deps.harness, problems)

  const first = await deps.session(prompt(ask.current))
  const answer = jsonAnswer(first.stdout)
  if (answer === null) {
    if (deps.stopped?.() === true) throw new HostError('unavailable', 'The run was stopped.')
    throw new HostError(
      'unavailable',
      `The agent did not answer with JSON: ${reasonOf(first.stdout, first.stderr)}`.trim(),
    )
  }

  const checked = await deps.run({
    binary: 'synapse-pipeline',
    args: ['check', ask.pipeline, '--input', '-'],
    stdin: answer,
    config: deps.config,
  })
  if (checked.code !== 2 || deps.stopped?.() === true) return answer
  const problems = checked.stderr
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.startsWith('error:'))
  const second = await deps.session(prompt(answer, problems))
  return jsonAnswer(second.stdout) ?? answer
}
