// Having an agent write a note of the vault from a description. Unlike the text an
// agent returns for a definition, a note has to follow the vault's own rules: a
// folder from Index.md, an id from a shared counter, tags from the vocabulary, links
// to the notes that exist. Those are the skills Synapse ships, so the agent is a
// headless session with Synapse loaded, tools limited to what writing a note takes,
// and the new note is found by comparing the vault before and after.

import { execFile } from 'node:child_process'
import { tmpdir } from 'node:os'
import type { CliResult, Harness, NoteKind } from '../shared/transport.ts'
import type { SessionPlan } from './inject.ts'

const TIMEOUT_MS = 10 * 60_000
const MAX_OUTPUT_BYTES = 1024 * 1024

// Why a note was not written, with the status the caller should see.
export class NoteFailed extends Error {
  status: number

  constructor(message: string, status = 502) {
    super(message)
    this.status = status
  }
}

const KIND_INSTRUCTIONS: Record<NoteKind, string> = {
  note: 'a plain note: use the synapse-note skill in bare mode',
  task: 'a tracked task note: use the synapse-note skill with --task',
  design: 'a design note: use the synapse-design-note skill',
}

// Claude Code and OpenCode run a command only when the whole of it is allowed, so the
// session is told which commands those are. Codex runs anything inside its sandbox.
const COMMAND_RULES =
  'Only these commands work in this session: synapse, ls, cat, head, tail, grep, sort and wc. Run one command in each Bash call: do not chain commands with ;, && or ||, do not use cd or echo, and write paths out in full, with ~ and not a variable.'

export function notePrompt(kind: NoteKind, description: string, harness: Harness): string {
  return [
    'Create one note in my Synapse Vault from the description below. Nobody can answer questions in this session, so decide what you would otherwise ask and carry on.',
    '',
    `Write ${KIND_INSTRUCTIONS[kind]}. Follow that skill and the synapse-vault skill: search the vault first and link to the notes that already exist, put the note where the skill says, tag it, and write the content the description asks for. The note is not finished while it is only a title.`,
    '',
    ...(harness === 'Codex' ? [] : [COMMAND_RULES, '']),
    "Give a note's text to `synapse vault-write <path>`, and a query to `synapse vault-search`, on standard input as a here-document, not through cat, echo or <<<: the synapse program is the only thing that may write here. When the note is in a top-level folder that Index.md does not list, add the folder to Index.md as the skill says, with `synapse vault-patch` or `synapse vault-write`.",
    '',
    'When the note is written, end your reply with one line that holds its path in the vault, as `synapse vault-list` shows it. If you cannot write it, end with one line that starts with FAILED: and says why.',
    '',
    'Description:',
    description.trim(),
  ].join('\n')
}

// The read-only commands the skills chain the synapse program with.
const HELPERS = ['ls', 'head', 'tail', 'cat', 'grep', 'sort', 'wc']

// The files the skills keep their lists in, which a session may read and change.
const LIST_FILES = ['~/.config/synapse/**', '~/.claude/synapse-*.conf']

// What a Claude Code session may use: the skills, the Synapse program with the
// read-only commands, and the files the skills keep their lists in. A command that
// chains one of these with anything else is refused whole, and anything else is
// refused, not asked.
export const NOTE_TOOLS = [
  'Skill',
  'Read',
  ...LIST_FILES.map((file) => `Read(${file})`),
  'Bash(synapse *)',
  ...HELPERS.map((command) => `Bash(${command} *)`),
  ...LIST_FILES.map((file) => `Edit(${file})`),
].join(',')

// The same for OpenCode: a command is allowed by its start, and all else is denied.
export const OPENCODE_PERMISSION: {
  bash: Record<string, string>
  edit: Record<string, string>
  webfetch: string
} = {
  bash: {
    '*': 'deny',
    'synapse *': 'allow',
    ...Object.fromEntries(HELPERS.map((command) => [`${command} *`, 'allow'])),
  },
  edit: { '*': 'deny', ...Object.fromEntries(LIST_FILES.map((file) => [file, 'allow'])) },
  webfetch: 'deny',
}

export interface NoteCommand {
  args: string[]
  // Added to the session's environment.
  env: Record<string, string>
  stdin: string
}

// The headless session of each harness, with what the session plan adds to load
// Synapse. Claude Code and OpenCode are held to the commands above. Codex runs in
// its sandbox, which writes only to its working folder and the folders in
// `writable`, where the vault and the skills' files are, and has no network.
export function noteCommand(
  harness: Harness,
  plan: SessionPlan,
  prompt: string,
  writable: readonly string[],
): NoteCommand {
  switch (harness) {
    case 'Claude':
      return {
        args: [
          '-p',
          '--output-format',
          'text',
          '--no-session-persistence',
          '--permission-mode',
          'dontAsk',
          '--allowedTools',
          // The folder of the Synapse package, when it is loaded for the session, is
          // there to be read: its skills and the schemas the vault holds notes to.
          plan.env.SYNAPSE_CONTENT_ROOT === undefined
            ? NOTE_TOOLS
            : `${NOTE_TOOLS},Read(${plan.env.SYNAPSE_CONTENT_ROOT}/**)`,
          ...plan.args,
        ],
        env: {},
        stdin: prompt,
      }
    case 'Codex':
      return {
        args: [
          'exec',
          '--ephemeral',
          '--skip-git-repo-check',
          '-s',
          'workspace-write',
          '-c',
          'approval_policy="never"',
          ...writable.flatMap((dir) => ['--add-dir', dir]),
          ...plan.args,
          '-',
        ],
        env: {},
        stdin: prompt,
      }
    case 'Opencode':
      return {
        args: ['run', '--standalone', '--auto', ...plan.args, prompt],
        env: { OPENCODE_CONFIG_CONTENT: JSON.stringify({ permission: OPENCODE_PERMISSION }) },
        stdin: '',
      }
  }
}

export interface NoteSessionRun {
  harness: Harness
  prompt: string
  // The environment the session runs in.
  env: Record<string, string>
  // The folders the session writes in besides its own: the vault, and where the
  // skills keep their files.
  writable: readonly string[]
}

export type NoteSession = (run: NoteSessionRun) => Promise<CliResult>

// A non-zero exit is a result, not an error. The session runs in an empty folder,
// so that no project instructions are loaded into it.
export function createNoteSession(plan: (harness: Harness) => Promise<SessionPlan>): NoteSession {
  return async (run) => {
    const session = await plan(run.harness)
    const { args, env, stdin } = noteCommand(run.harness, session, run.prompt, run.writable)
    return new Promise((resolve, reject) => {
      const child = execFile(
        session.command,
        args,
        {
          cwd: tmpdir(),
          env: { ...run.env, ...session.env, ...env },
          timeout: TIMEOUT_MS,
          maxBuffer: MAX_OUTPUT_BYTES,
        },
        (error, stdout, stderr) => {
          if (error === null) resolve({ code: 0, stdout, stderr })
          else if (typeof error.code === 'number') resolve({ code: error.code, stdout, stderr })
          else reject(new Error(`${session.command} could not be run: ${error.message}`))
        },
      )
      child.stdin?.end(stdin)
    })
  }
}

function lastLine(text: string): string {
  return (
    text
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line !== '')
      .at(-1) ?? ''
  )
}

// The reason the agent gave for not writing the note, when it said so.
export function failureOf(stdout: string): string | null {
  const line = lastLine(stdout)
  return line.startsWith('FAILED:') ? line.slice('FAILED:'.length).trim() : null
}

// The note that was written: the one the agent named when it is among the notes
// that were not there before, else the first new note that is not a graph's.
export function createdPath(
  stdout: string,
  before: ReadonlySet<string>,
  after: readonly string[],
): string | null {
  const added = after.filter((path) => !before.has(path) && path.endsWith('.md'))
  const said = lastLine(stdout).replace(/^[`'"]+|[`'".]+$/g, '')
  if (said !== '' && added.includes(said)) return said
  return added.find((path) => !path.startsWith('synapse/')) ?? null
}

export function pathsOf(listing: string): string[] {
  return listing.split('\n').filter((line) => line !== '')
}

// The vault's folder in the output of `synapse config list --format json`.
export function vaultDirOf(listing: string): string | null {
  try {
    const parsed = JSON.parse(listing) as { settings?: { key?: string; value?: unknown }[] }
    const value = parsed.settings?.find((setting) => setting.key === 'SYNAPSE_VAULT_DIR')?.value
    return typeof value === 'string' && value !== '' ? value : null
  } catch {
    return null
  }
}
