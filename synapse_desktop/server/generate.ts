// Having an agent write the text of a definition from a description. The agent
// is a headless session with no tools: it answers with text, which the editor
// shows and the program then checks like any other text.

import { execFile } from 'node:child_process'
import { access, readFile, realpath } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { delimiter, dirname, join } from 'node:path'
import type { CliResult, GenerateRequest, Harness } from '../shared/transport.ts'

const TIMEOUT_MS = 180_000
const MAX_OUTPUT_BYTES = 1024 * 1024

export interface AgentRun {
  // Variables set in the app, over those the server has.
  env?: Record<string, string>
  harness: Harness
  // The model the session is asked to use; the harness's own when absent.
  model?: string
  // Added to the session's own instructions.
  system: string
  prompt: string
}

export type AgentRunner = (run: AgentRun) => Promise<CliResult>

export class SkillNotFound extends Error {}
export class GenerationFailed extends Error {}

export interface AgentCommand {
  program: string
  args: string[]
  env: Record<string, string>
  stdin: string
}

// The headless session of a harness that can read and answer but not change
// anything or run anything. Codex and OpenCode have no flag for added
// instructions, so those go in front of the prompt.
export function agentCommand({ harness, model, system, prompt }: AgentRun): AgentCommand {
  const together = `${system}\n\n${prompt}`
  switch (harness) {
    case 'Claude':
      return {
        program: 'claude',
        args: [
          '-p',
          '--output-format',
          'text',
          '--no-session-persistence',
          '--permission-mode',
          'dontAsk',
          '--tools',
          '',
          '--append-system-prompt',
          system,
          ...(model === undefined ? [] : ['--model', model]),
        ],
        env: {},
        stdin: prompt,
      }
    case 'Codex':
      return {
        program: 'codex',
        args: [
          'exec',
          '--ephemeral',
          '--skip-git-repo-check',
          '-s',
          'read-only',
          ...(model === undefined ? [] : ['-m', model]),
        ],
        env: {},
        stdin: together,
      }
    case 'Opencode':
      return {
        program: 'opencode',
        args: [
          'run',
          '--standalone',
          '--auto',
          ...(model === undefined ? [] : ['-m', model]),
          together,
        ],
        env: {
          OPENCODE_CONFIG_CONTENT: JSON.stringify({
            permission: {
              edit: 'deny',
              bash: 'deny',
              webfetch: 'deny',
              external_directory: 'deny',
            },
          }),
        },
        stdin: '',
      }
  }
}

// A non-zero exit is a result, not an error. The session runs in an empty
// directory so that no project instructions are loaded into it.
export const runAgent: AgentRunner = (run) =>
  new Promise((resolve, reject) => {
    const { program, args, env, stdin } = agentCommand(run)
    const child = execFile(
      program,
      args,
      {
        cwd: tmpdir(),
        env: { ...process.env, ...run.env, ...env },
        timeout: TIMEOUT_MS,
        maxBuffer: MAX_OUTPUT_BYTES,
      },
      (error, stdout, stderr) => {
        if (error === null) resolve({ code: 0, stdout, stderr })
        else if (typeof error.code === 'number') resolve({ code: error.code, stdout, stderr })
        else reject(new Error(`${program} could not be run: ${error.message}`))
      },
    )
    child.stdin?.end(stdin)
  })

// The text of the skill that comes with `synapse-pipeline`: it sits in the
// package next to the program's launcher, which is a link on PATH.
export async function findPipelineSkill(pathVariable: string): Promise<string> {
  for (const dir of pathVariable.split(delimiter).filter(Boolean)) {
    const launcher = join(dir, 'synapse-pipeline')
    const real = await realpath(launcher).catch(() => null)
    if (real === null) continue
    const skill = join(dirname(real), '..', 'skills', 'synapse-pipeline', 'SKILL.md')
    if (
      await access(skill).then(
        () => true,
        () => false,
      )
    )
      return readFile(skill, 'utf8')
  }
  throw new SkillNotFound('the synapse-pipeline skill was not found next to the program')
}

// The part of the skill that says what definitions are and how they behave: from
// "Definitions" up to the part about running them.
export function referenceFrom(skill: string): string {
  const start = skill.indexOf('\n## Definitions')
  const end = skill.indexOf('\n## Trying a pipeline without agents')
  if (start === -1 || end === -1 || end < start) {
    throw new GenerationFailed('the synapse-pipeline skill has an unknown layout')
  }
  return skill.slice(start, end).trim()
}

const REPLY_RULES = `Reply with the text of one file and nothing else: no code fences, no explanation before or after. You cannot run commands or write files here; the text you give is checked afterwards, so it has to be right as written.`

const SKILL_FORMAT = `A skill is a SKILL.md: frontmatter between --- lines holding name (1 to 64 lowercase letters, digits and single hyphens) and description (what the skill does and when to use it), then the instructions the agent follows.`

const REVISE_RULES = `You are given the current text of the file. Reply with the whole revised text, with the same name and the same kind of definition, and change only what the description asks for.`

export function systemFor(request: GenerateRequest, skill: string): string {
  const revising = request.current === undefined ? '' : `\n\n${REVISE_RULES}`
  if (request.kind === 'skill') {
    return `You write skills for coding agents. ${SKILL_FORMAT}\n\n${REPLY_RULES}${revising}`
  }
  const wanted = {
    pipeline:
      "a Pipeline: a single file, with each step's role and instructions in its own Prompt. Refer to an existing Agent or System only when one in the list below fits. Give every step a Harness and say in its prompt the exact outcome words it may report. Every back-edge needs Max_Iterations.",
    system: 'a System: one reusable setup that steps can share.',
    agent: 'an Agent: one role, a Prompt that says who the session is.',
  }[request.kind]
  return `You write definition files for synapse-pipeline. Write ${wanted}\n\n${REPLY_RULES}${revising}\n\n${referenceFrom(skill)}`
}

export function promptFor(request: GenerateRequest): string {
  const lines =
    request.current === undefined
      ? [`Write a new ${request.kind} as described here.`, '', request.prompt.trim()]
      : [
          `Change this ${request.kind} as described here.`,
          '',
          request.prompt.trim(),
          '',
          'The current text:',
          '',
          request.current,
        ]
  if (request.kind !== 'skill' && request.definitions.length > 0) {
    lines.push(
      '',
      'Definitions that exist (a name is taken by any of them):',
      ...request.definitions.map((d) => `- ${d.kind} ${d.name}`),
    )
  }
  if (request.kind === 'skill' && request.skills.length > 0) {
    lines.push(
      '',
      `Skills that exist (a name is taken by any of them): ${request.skills.join(', ')}`,
    )
  }
  return lines.join('\n')
}

// What the agent answered, as the text of the file: a reply wrapped in a code
// fence has the fence taken off.
export function textOf(answer: string): string {
  const trimmed = answer.trim()
  const fenced = /^```[^\n]*\n([\s\S]*?)\n?```$/.exec(trimmed)
  return `${(fenced?.[1] ?? trimmed).trim()}\n`
}

export async function generateText(
  request: GenerateRequest,
  deps: {
    pathVariable: string
    agent: AgentRunner
    harness: Harness
    model?: string
    env: Record<string, string>
  },
): Promise<string> {
  const skill = request.kind === 'skill' ? '' : await findPipelineSkill(deps.pathVariable)
  const result = await deps.agent({
    env: deps.env,
    harness: deps.harness,
    ...(deps.model === undefined ? {} : { model: deps.model }),
    system: systemFor(request, skill),
    prompt: promptFor(request),
  })
  if (result.code !== 0) {
    const reason = result.stderr.trim().split('\n').pop() ?? ''
    throw new GenerationFailed(`the agent failed${reason === '' ? '' : `: ${reason}`}`)
  }
  const text = textOf(result.stdout)
  if (text.trim() === '') throw new GenerationFailed('the agent answered with nothing')
  return text
}
