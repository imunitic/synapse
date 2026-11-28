// Having an agent write a note of the vault from a description. Unlike the text an
// agent returns for a definition, a note has to follow the vault's own rules: a
// folder from Index.md, an id from a shared counter, tags from the vocabulary, links
// to the notes that exist. Those are the skills Synapse ships, so the agent is a
// headless session with Synapse loaded, tools limited to what writing a note takes,
// and the new note is found by comparing the vault before and after.

import { execFile } from 'node:child_process'
import { mkdtemp, realpath, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { CliResult, Harness, NoteKind, Project } from '../shared/transport.ts'
import type { SessionPlan } from './inject.ts'
import { modelArgs } from './harness-args.ts'
import { HostError } from '../shared/dispatch.ts'
import type { ErrorCode } from '../shared/protocol.ts'

const TIMEOUT_MS = 10 * 60_000
const MAX_OUTPUT_BYTES = 1024 * 1024

// Why a note was not written, with the status the caller should see.
export class NoteFailed extends HostError {
  constructor(message: string, code: ErrorCode = 'unavailable') {
    super(code, message)
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

// What a task or design note is told about its project: the one chosen, else the ones
// there are to match the description to. A project is made by a person on the page,
// never by the session, and a plain note has none.
export function projectParagraph(
  kind: NoteKind,
  projects: readonly Project[],
  chosen?: Project,
): string[] {
  if (kind === 'note') return []
  const folder = kind === 'task' ? 'tasks' : 'designs'
  if (chosen !== undefined) {
    return [
      `The project of this note is ${chosen.name}, with the prefix ${chosen.prefix}: use it as it is and do not resolve another. The note is in ${folder}/${chosen.name}/ and its project is ${chosen.prefix}.`,
      '',
    ]
  }
  const known =
    projects.length === 0
      ? 'There are none.'
      : projects.map((project) => `${project.name}=${project.prefix}`).join(', ')
  return [
    `The projects of this machine, as name=prefix: ${known} A note of the project NAME with the prefix PREFIX is in ${folder}/NAME/ and has the project PREFIX. Choose the project the description belongs to, matching loosely: a description about a part of a project belongs to that project.`,
    'Never add a project, since that file is not yours to change here. If none fits the description, write nothing and end with FAILED: saying that no project fits, so that the person can add one on the page.',
    '',
  ]
}

// How input is given to the synapse program in a session that may only write through it.
const HERE_DOCUMENT_RULE =
  "Give a note's text to `synapse vault-write <path>`, and a query to `synapse vault-search`, on standard input as a here-document, not through cat, echo or <<<: the synapse program is the only thing that may write here."

// How a note that is changed is handed to the synapse program by a session that may edit only the
// files of its own folder. A command that carries the whole text of a long note is refused, so the
// note is saved to a file there, changed with the edit tool and written back from the file.
const WORK_FILE_RULE =
  'Save the note in the current folder with `synapse vault-read <path> > note.md`, change it there with the Edit tool, and write it back with `synapse vault-write <path> < note.md`. Give the synapse program its input from a file in the current folder, made with the Write tool and read with `<`, never as a here-document and never through cat, echo or <<<: a command that carries the text is refused, as the whole text of a long note is and as a JSON query is. A query for `synapse vault-search` is in query.json and run as `synapse vault-search < query.json`; the text of an addition for `synapse vault-patch` is in addition.md. The synapse program is the only thing that may write to the vault.'

// The same for a note that is made: it is written to a file there with the Write tool and given to the
// vault from the file.
const NEW_NOTE_FILE_RULE =
  'Write the note with the Write tool to note.md in the current folder, and give it to the vault with `synapse vault-write <path> < note.md`. Give the synapse program its input from a file in the current folder, made with the Write tool and read with `<`, never as a here-document and never through cat, echo or <<<: a command that carries the text is refused, as the whole text of a long note is and as a JSON query is. A query for `synapse vault-search` is in query.json and run as `synapse vault-search < query.json`; the text of an addition for `synapse vault-patch` is in addition.md. The synapse program is the only thing that may write to the vault. When the note is in a top-level folder that Index.md does not list, add the folder to Index.md as the skill says.'

// The prompt to change one note that is there already. The agent is held to that note
// by what it is told, and the app checks afterwards that no other note moved.
export function editPrompt(path: string, description: string, harness: Harness): string {
  return [
    `Change one note that already exists in my Synapse Vault, as the description below says. The note is \`${path}\`: read it first with \`synapse vault-read\`. Nobody can answer questions in this session, so decide what you would otherwise ask and carry on.`,
    '',
    'Follow the synapse-vault skill, and for a task note the synapse-task skill: a checklist moves the status up to REVIEW and never to DONE. Change only what the description asks for, and change no other note. Edit with `synapse vault-patch` when a heading or a field is the target, or write the whole note again with `synapse vault-write` from what you read, keeping every frontmatter field, section, link and line you were not asked to change. Never change `schema`, `note_id`, `task_id`, `created` or `project`, and set `updated` from `synapse now`.',
    '',
    ...(harness === 'Codex' ? [] : [COMMAND_RULES, '']),
    harness === 'Claude' ? WORK_FILE_RULE : HERE_DOCUMENT_RULE,
    '',
    'When the note is changed, end your reply with the line EDITED. If you cannot change it, or the description asks for what you may not do, end with one line that starts with FAILED: and says why.',
    '',
    'Description:',
    description.trim(),
  ].join('\n')
}

export function notePrompt(
  kind: NoteKind,
  description: string,
  harness: Harness,
  projects: readonly Project[] = [],
  chosen?: Project,
): string {
  return [
    'Create one note in my Synapse Vault from the description below. Nobody can answer questions in this session, so decide what you would otherwise ask and carry on.',
    '',
    `Write ${KIND_INSTRUCTIONS[kind]}. Follow that skill and the synapse-vault skill: search the vault first and link to the notes that already exist, put the note where the skill says, tag it, and write the content the description asks for. The note is not finished while it is only a title.`,
    '',
    ...(harness === 'Codex' ? [] : [COMMAND_RULES, '']),
    harness === 'Claude'
      ? NEW_NOTE_FILE_RULE
      : "Give a note's text to `synapse vault-write <path>`, and a query to `synapse vault-search`, on standard input as a here-document, not through cat, echo or <<<: the synapse program is the only thing that may write here. When the note is in a top-level folder that Index.md does not list, add the folder to Index.md as the skill says, with `synapse vault-patch` or `synapse vault-write`.",
    '',
    ...projectParagraph(kind, projects, chosen),
    'When the note is written, end your reply with one line that holds its path in the vault, as `synapse vault-list` shows it. If you cannot write it, end with one line that starts with FAILED: and says why.',
    '',
    'Description:',
    description.trim(),
  ].join('\n')
}

// The read-only commands the skills chain the synapse program with.
const HELPERS = ['ls', 'head', 'tail', 'cat', 'grep', 'sort', 'wc']

// The files the skills keep their lists in, which a session may read.
const LIST_FILES = ['~/.config/synapse/**', '~/.claude/synapse-*.conf']

// The only list a session may add to: the tag vocabulary. A project is chosen by a
// person, since it names the folder and the prefix of every note after it, so
// `synapse-projects.conf` is read and never changed here.
const TAG_FILES = [
  '~/.config/synapse/synapse-tag-vocabulary.conf',
  '~/.claude/synapse-tag-vocabulary.conf',
]

// What a Claude Code session may use: the skills, the Synapse program with the
// read-only commands, reading the files the skills keep their lists in, adding to
// the tag vocabulary, and editing the files of its own folder, which is empty and
// removed when the session ends. A command that chains one of these with anything
// else is refused whole, and anything else is refused, not asked.
export const NOTE_TOOLS = [
  'Skill',
  'Read',
  ...LIST_FILES.map((file) => `Read(${file})`),
  'Bash(synapse *)',
  ...HELPERS.map((command) => `Bash(${command} *)`),
  ...TAG_FILES.map((file) => `Edit(${file})`),
  'Edit(./**)',
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
  edit: { '*': 'deny', ...Object.fromEntries(TAG_FILES.map((file) => [file, 'allow'])) },
  webfetch: 'deny',
}

// What a session may do: write notes as the skills say, or only read and search the vault, as the
// session that fills in the input of a run does.
export type Access = 'write' | 'read'

// What a Claude Code session that only reads may use: the three vault commands that read and
// search, and nothing else, no skill, no file and no edit.
export const READ_TOOLS = [
  'Bash(synapse vault-search-text *)',
  'Bash(synapse vault-list)',
  'Bash(synapse vault-list *)',
  'Bash(synapse vault-read *)',
].join(',')

// The same for OpenCode: those commands, and every other command and every edit denied.
export const OPENCODE_READ_PERMISSION: {
  bash: Record<string, string>
  edit: Record<string, string>
  webfetch: string
} = {
  bash: {
    '*': 'deny',
    'synapse vault-search-text *': 'allow',
    'synapse vault-list*': 'allow',
    'synapse vault-read *': 'allow',
  },
  edit: { '*': 'deny' },
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
// `writable`, where the vault and the skills' files are, and has no network. A read
// session is held to the commands that read and search the vault, and Codex to its
// read-only sandbox.
export function noteCommand(
  harness: Harness,
  plan: SessionPlan,
  prompt: string,
  writable: readonly string[],
  model?: string,
  effort?: string,
  stream = false,
  access: Access = 'write',
): NoteCommand {
  const reading = access === 'read'
  switch (harness) {
    case 'Claude':
      return {
        args: [
          '-p',
          '--output-format',
          ...(stream ? ['stream-json', '--verbose'] : ['text']),
          '--no-session-persistence',
          '--permission-mode',
          'dontAsk',
          '--allowedTools',
          // The folder of the Synapse package, when it is loaded for the session, is
          // there to be read: its skills and the schemas the vault holds notes to.
          reading
            ? READ_TOOLS
            : plan.env.SYNAPSE_CONTENT_ROOT === undefined
              ? NOTE_TOOLS
              : `${NOTE_TOOLS},Read(${plan.env.SYNAPSE_CONTENT_ROOT}/**)`,
          ...plan.args,
          ...modelArgs(harness, model, effort),
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
          reading ? 'read-only' : 'workspace-write',
          '-c',
          'approval_policy="never"',
          ...(reading ? [] : writable.flatMap((dir) => ['--add-dir', dir])),
          ...plan.args,
          ...modelArgs(harness, model, effort),
          '-',
        ],
        env: {},
        stdin: prompt,
      }
    case 'Opencode':
      return {
        args: [
          'run',
          '--standalone',
          '--auto',
          ...plan.args,
          ...modelArgs(harness, model, effort),
          prompt,
        ],
        env: {
          OPENCODE_CONFIG_CONTENT: JSON.stringify({
            permission: reading ? OPENCODE_READ_PERMISSION : OPENCODE_PERMISSION,
          }),
        },
        stdin: '',
      }
  }
}

export interface NoteSessionRun {
  harness: Harness
  prompt: string
  // The model the session is asked to use; the harness's own when absent.
  model?: string
  // The effort the session is asked for; the harness's own when absent.
  effort?: string
  // The environment the session runs in.
  env: Record<string, string>
  // The folders the session writes in besides its own: the vault, and where the
  // skills keep their files.
  writable: readonly string[]
  // Whether the session writes notes or only reads the vault; it writes when absent.
  access?: Access
  // Ends the session when aborted; the result is then code 143.
  signal?: AbortSignal
  // Called with each line the session prints, as it prints it. For Claude the session
  // prints its events as stream-json, and the stdout of the result is the final text.
  onLine?: (line: string) => void
}

export type NoteSession = (run: NoteSessionRun) => Promise<CliResult>

// A non-zero exit is a result, not an error. The session runs in an empty folder of its
// own, so that no project instructions are loaded into it and the files it makes there
// are gone when it ends.
// What the session is told after the prompt: where its folder is, written out, since the edit tool
// takes a full path and has no other way to know it.
export function folderSentence(folder: string): string {
  return `Your current folder is ${folder}: a file you make there, such as note.md, is at that path.`
}

// The prompt a session is given: the sentence about its folder comes first, so that the prompt still
// ends with the description of what is asked.
export function sessionPrompt(prompt: string, folder: string): string {
  return `${folderSentence(folder)}\n\n${prompt}`
}

// The text of the final `result` event of a stream-json transcript, '' when there is none.
export function streamResult(stdout: string): string {
  const lines = stdout.split('\n')
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    try {
      const event = JSON.parse(lines[index] ?? '') as { type?: unknown; result?: unknown }
      if (event !== null && typeof event === 'object' && event.type === 'result') {
        return typeof event.result === 'string' ? event.result : ''
      }
    } catch {
      // Not an event: the line is skipped.
    }
  }
  return ''
}

// Hands over each complete non-empty line of the chunks written to it, and the last line,
// which may have no newline, on `end`.
export function lineSplitter(onLine: (line: string) => void): {
  write(chunk: string): void
  end(): void
} {
  let rest = ''
  return {
    write(chunk) {
      const parts = (rest + chunk).split('\n')
      rest = parts.pop() ?? ''
      for (const part of parts) if (part.trim() !== '') onLine(part)
    },
    end() {
      if (rest.trim() !== '') onLine(rest)
      rest = ''
    },
  }
}

export function createNoteSession(plan: (harness: Harness) => Promise<SessionPlan>): NoteSession {
  return async (run) => {
    const session = await plan(run.harness)
    // The real path: the permission rules compare it with the path a file is made at.
    const folder = await realpath(await mkdtemp(join(tmpdir(), 'synapse-note-')))
    const { args, env, stdin } = noteCommand(
      run.harness,
      session,
      sessionPrompt(run.prompt, folder),
      run.writable,
      run.model,
      run.effort,
      run.onLine !== undefined && run.harness === 'Claude',
      run.access,
    )
    const streaming = run.onLine !== undefined && run.harness === 'Claude'
    const lines = run.onLine === undefined ? undefined : lineSplitter(run.onLine)
    const running = new Promise<CliResult>((resolve, reject) => {
      const child = execFile(
        session.command,
        args,
        {
          cwd: folder,
          env: { ...run.env, ...session.env, ...env },
          timeout: TIMEOUT_MS,
          maxBuffer: MAX_OUTPUT_BYTES,
          ...(run.signal === undefined ? {} : { signal: run.signal }),
        },
        (error, stdout, stderr) => {
          lines?.end()
          const text = streaming ? streamResult(stdout) : stdout
          if (error === null) resolve({ code: 0, stdout: text, stderr })
          else if (error.name === 'AbortError') resolve({ code: 143, stdout: text, stderr })
          else if (typeof error.code === 'number') {
            resolve({ code: error.code, stdout: text, stderr })
          } else reject(new Error(`${session.command} could not be run: ${error.message}`))
        },
      )
      if (lines !== undefined) child.stdout?.on('data', (chunk) => lines.write(String(chunk)))
      child.stdin?.end(stdin)
    })
    try {
      return await running
    } finally {
      await rm(folder, { recursive: true, force: true })
    }
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

// The colours a harness prints in.
// eslint-disable-next-line no-control-regex -- the escape character is what starts a colour
const COLOUR = /\u001b\[[0-9;]*m/g

function lastWords(text: string): string {
  return text.replace(COLOUR, '').trim().slice(-300)
}

// Why a session that was to write or change a note did not: the reason it gave on a line
// that starts with FAILED:, else the end of what it said, else the end of what the harness
// printed on standard error. What it said comes first because some harnesses print their whole
// transcript on standard error, the banner and the prompt among it, and the agent's own words
// are on standard output.
export function reasonOf(stdout: string, stderr: string): string {
  return failureOf(stdout) ?? (lastWords(stdout) || lastWords(stderr))
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
