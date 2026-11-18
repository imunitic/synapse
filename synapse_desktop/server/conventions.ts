// The configuration files Synapse keeps in the user's configuration directory: tag
// vocabulary, stopwords, the rules of the code graph and the projects. An agent writes
// most of them, and a person can add to them or take an entry out. A file of lines
// (one entry a line, `#` for a comment) can be changed here; a file of JSON is shown
// as it is, since its entries are structured and the code graph checks them when it
// reads them.

import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import type {
  Convention,
  ConventionEntry,
  ConventionGroup,
  ConventionList,
  ProjectList,
} from '../shared/transport.ts'
import { confFile } from './conf-files.ts'
import { ProjectRefused } from './projects.ts'
import type { Environment } from './roots.ts'
import { HostError } from '../shared/dispatch.ts'
import type { ErrorCode } from '../shared/protocol.ts'

// Where the projects are read and added: `synapse projects`, which finds the file and checks what
// is added, so that the rules of a project are not kept here as well.
export interface ProjectsSource {
  load: () => Promise<ProjectList>
  add: (name: string, prefix: string) => Promise<ProjectList>
}

export class ConventionRefused extends HostError {
  constructor(message: string, code: ErrorCode = 'bad_request') {
    super(code, message)
  }
}

type Kind = 'lines' | 'projects' | 'json'

interface Definition {
  id: string
  group: ConventionGroup
  title: string
  about: string
  file: string
  kind: Kind
}

export const DEFINITIONS: readonly Definition[] = [
  {
    id: 'projects',
    group: 'Vault',
    title: 'Projects',
    about:
      'The folder and the id prefix of each project’s notes, one name=prefix to a line. A person makes them; a note session never does.',
    file: 'synapse-projects.conf',
    kind: 'projects',
  },
  {
    id: 'tags',
    group: 'Vault',
    title: 'Tag vocabulary',
    about: 'The tags a note may take, one to a line.',
    file: 'synapse-tag-vocabulary.conf',
    kind: 'lines',
  },
  {
    id: 'grammars',
    group: 'Code graph',
    title: 'Grammars',
    about: 'Which grammar serves each file extension, and where it comes from.',
    file: 'synapse-grammars.conf',
    kind: 'json',
  },
  {
    id: 'namespace-rules',
    group: 'Code graph',
    title: 'Namespace rules',
    about: 'How the namespace a file declares is found, by file extension.',
    file: 'synapse-namespace-rules.conf',
    kind: 'json',
  },
  {
    id: 'dependency-rules',
    group: 'Code graph',
    title: 'Dependency rules',
    about: 'How what a file depends on is found, by file extension.',
    file: 'synapse-dependency-rules.conf',
    kind: 'json',
  },
  {
    id: 'kind-synonyms',
    group: 'Code graph',
    title: 'Kind synonyms',
    about:
      'How a grammar’s own name for a kind of symbol maps onto Synapse’s. Tried from the top; the first match wins.',
    file: 'synapse-kind-synonyms.conf',
    kind: 'json',
  },
  {
    id: 'fence-languages',
    group: 'Code graph',
    title: 'Fence languages',
    about: 'The language a code block in a node gets, by file extension.',
    file: 'synapse-fence-languages.conf',
    kind: 'json',
  },
  {
    id: 'module-boilerplate',
    group: 'Code graph',
    title: 'Module boilerplate',
    about:
      'Path segments that are not part of a module’s name, such as a source root, one chain to a line.',
    file: 'synapse-module-boilerplate.conf',
    kind: 'lines',
  },
  {
    id: 'ignore-files',
    group: 'Code graph',
    title: 'Ignored files',
    about: 'Extra path patterns left out when the graph is built, one to a line.',
    file: 'synapse-ignore-files.conf',
    kind: 'lines',
  },
  {
    id: 'comment-style-rules',
    group: 'Code graph',
    title: 'Comment style rules',
    about: 'How comments are to be written in this code, for the agent to follow.',
    file: 'synapse-comment-style-rules.conf',
    kind: 'lines',
  },
  {
    id: 'stopwords',
    group: 'Prompts',
    title: 'Prompt stopwords',
    about: 'Words dropped when a prompt is turned into a search, one to a line.',
    file: 'synapse-prompt-stopwords.conf',
    kind: 'lines',
  },
]

// The entries of a file of lines: what is not blank and not a comment, trimmed.
export function parseLines(text: string): string[] {
  const lines: string[] = []
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line !== '' && !line.startsWith('#')) lines.push(line)
  }
  return lines
}

// One line to show for a JSON value.
function oneLine(value: unknown): string {
  return JSON.stringify(value) ?? 'null'
}

// The entries of a file of JSON: for an object each key with its value, for a list each
// rule in order. The text of the problem when it is not JSON, or is another shape.
export function parseJson(text: string): { entries: ConventionEntry[] } | { problem: string } {
  if (text.trim() === '') return { entries: [] }
  let value: unknown
  try {
    value = JSON.parse(text)
  } catch (error) {
    return { problem: `It is not JSON: ${error instanceof Error ? error.message : String(error)}` }
  }
  if (Array.isArray(value)) {
    return {
      entries: value.map((item, index) => ({ text: `${index + 1}`, detail: oneLine(item) })),
    }
  }
  if (value !== null && typeof value === 'object') {
    return {
      entries: Object.entries(value).map(([key, item]) => ({ text: key, detail: oneLine(item) })),
    }
  }
  return { problem: 'It is neither an object nor a list.' }
}

async function readOf(path: string): Promise<string | null> {
  return readFile(path, 'utf8').catch(() => null)
}

function projectLines(list: ProjectList): string[] {
  return list.projects.map((p) => `${p.name}=${p.prefix}`)
}

async function describe(
  environment: Environment,
  projects: ProjectsSource,
  definition: Definition,
): Promise<Convention> {
  let file = await confFile(environment, definition.file)
  let held: ProjectList | null = null
  let problem: string | null = null
  if (definition.kind === 'projects') {
    try {
      held = await projects.load()
      file = held.file
    } catch (error) {
      problem = error instanceof Error ? error.message : String(error)
    }
  }
  const text = await readOf(file)
  const base = {
    id: definition.id,
    group: definition.group,
    title: definition.title,
    about: definition.about,
    file,
    exists: text !== null,
    editable: definition.kind !== 'json',
  }
  if (definition.kind === 'projects') {
    return {
      ...base,
      entries: (held === null ? [] : projectLines(held)).map((line) => ({ text: line })),
      problem,
    }
  }
  if (text === null) return { ...base, entries: [], problem: null }
  if (definition.kind === 'json') {
    const parsed = parseJson(text)
    return 'problem' in parsed
      ? { ...base, entries: [], problem: parsed.problem }
      : { ...base, entries: parsed.entries, problem: null }
  }
  return { ...base, entries: parseLines(text).map((line) => ({ text: line })), problem: null }
}

export async function listConventions(
  environment: Environment,
  projects: ProjectsSource,
): Promise<ConventionList> {
  return {
    conventions: await Promise.all(DEFINITIONS.map((d) => describe(environment, projects, d))),
  }
}

function definitionFor(id: string): Definition {
  const found = DEFINITIONS.find((d) => d.id === id)
  if (found === undefined)
    throw new ConventionRefused(`There is no file called ${id}.`, 'not_found')
  if (found.kind === 'json') {
    throw new ConventionRefused(`${found.title} is changed in its file, not here.`, 'conflict')
  }
  return found
}

// What is wrong with a line to add, or null.
function refusalOf(entry: string, known: readonly string[]): string | null {
  if (entry === '' || entry.includes('\n') || entry.includes('\r')) {
    return 'An entry is one line of text.'
  }
  if (entry.startsWith('#')) return 'An entry that starts with # would be a comment.'
  if (known.includes(entry)) return `${entry} is already there.`
  return null
}

export async function addConvention(
  environment: Environment,
  projects: ProjectsSource,
  id: string,
  rawEntry: string,
): Promise<ConventionList> {
  const definition = definitionFor(id)
  const entry = rawEntry.trim()
  if (definition.kind === 'projects') {
    // A project is written name=prefix; whether it may be added is for `synapse projects` to say.
    const at = entry.indexOf('=')
    if (at <= 0) throw new ConventionRefused('A project is written name=prefix.', 'conflict')
    try {
      await projects.add(entry.slice(0, at).trim(), entry.slice(at + 1).trim())
    } catch (error) {
      if (error instanceof ProjectRefused) throw new ConventionRefused(error.message, 'conflict')
      throw error
    }
    return listConventions(environment, projects)
  }
  const file = await confFile(environment, definition.file)
  const before = (await readOf(file)) ?? ''
  const refusal = refusalOf(entry, parseLines(before))
  if (refusal !== null) throw new ConventionRefused(refusal, 'conflict')
  await mkdir(dirname(file), { recursive: true })
  const separator = before === '' || before.endsWith('\n') ? '' : '\n'
  await writeFile(file, `${before}${separator}${entry}\n`)
  return listConventions(environment, projects)
}

// Takes the first line that is the entry out of the file, and leaves every other line,
// the comments among them, as it was.
export async function removeConvention(
  environment: Environment,
  projects: ProjectsSource,
  id: string,
  rawEntry: string,
): Promise<ConventionList> {
  const definition = definitionFor(id)
  const entry = rawEntry.trim()
  const file =
    definition.kind === 'projects'
      ? (await projects.load()).file
      : await confFile(environment, definition.file)
  const before = await readOf(file)
  const lines = (before ?? '').split('\n')
  const at = lines.findIndex((line) => line.trim() === entry && !line.trim().startsWith('#'))
  if (before === null || at < 0) {
    throw new ConventionRefused(`${entry} is not in ${definition.file}.`, 'not_found')
  }
  lines.splice(at, 1)
  await writeFile(file, lines.join('\n'))
  return listConventions(environment, projects)
}
