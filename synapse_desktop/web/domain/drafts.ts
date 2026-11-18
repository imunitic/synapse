// Text that is being written and is not saved yet: which definition it declares,
// what the program says about it, and where its problems are in the text.

import type { CliResult, Transport } from '../../shared/transport.ts'
import { readShown, parseProblems, type PipelineDescription, type Problem } from './pipelines.ts'
import { parseSkillMeta } from './skills.ts'

export type DraftKind = 'pipeline' | 'system' | 'agent'

export interface Declared {
  kind: DraftKind
  // The name the text declares, which is the name of its file.
  name: string
}

const KINDS = new Map<string, DraftKind>([
  ['Pipeline', 'pipeline'],
  ['System', 'system'],
  ['Agent', 'agent'],
])

// The kind and the name the text declares with its first two words, after any
// comments (`--` to the end of the line); null when it does not start with
// both.
export function declaredOf(text: string): Declared | null {
  const match = /^(?:\s|--[^\n]*)*([A-Za-z]+)\s+([A-Za-z][A-Za-z0-9_]*)/.exec(text)
  const kind = KINDS.get(match?.[1] ?? '')
  return kind === undefined || match?.[2] === undefined ? null : { kind, name: match[2] }
}

// Where a new definition starts.
export function templateFor(kind: DraftKind | 'skill'): string {
  switch (kind) {
    case 'pipeline':
      return [
        '-- Say what this pipeline does.',
        'Pipeline New_Pipeline {',
        '   First  [Harness => Claude, Prompt => "Say what this step does."];',
        '   Second [Harness => Claude, Prompt => "Say what this step does."];',
        '}',
        '',
      ].join('\n')
    case 'system':
      return [
        '-- A setup that steps can share.',
        'System New_System [Harness => Claude, Permissions => Workspace_Write];',
        '',
      ].join('\n')
    case 'agent':
      return [
        '-- A role that steps can take.',
        'Agent New_Agent [Prompt => "You are ... Say who the session is."];',
        '',
      ].join('\n')
    case 'skill':
      return [
        '---',
        'name: new-skill',
        'description: Say what this skill does and when to use it.',
        '---',
        '',
        'Write the instructions for the agent here.',
        '',
      ].join('\n')
  }
}

export interface Preview {
  // The pipeline the draft describes; null for a system or an agent, and when
  // the draft cannot run.
  description: PipelineDescription | null
  // What is wrong with the draft: every problem of a pipeline, and the warnings
  // that name the file of a system or an agent.
  problems: Problem[]
}

function fileOf(problem: Problem): string {
  return (problem.file ?? '').split(/[\\/]/).pop() ?? ''
}

// What the program says about a draft: the description of a pipeline, or the
// problems with it. Throws when the program answers in a format this app does
// not know.
export function readPreview(draft: Declared, result: CliResult): Preview {
  if (draft.kind === 'pipeline') {
    const shown = readShown(result)
    return shown.ok
      ? { description: shown.description, problems: [] }
      : { description: null, problems: shown.problems }
  }
  // A pipeline that stands for the others was checked: what it says about other
  // definitions that do not load is not about the draft.
  const own = `${draft.name}.synapse`
  return {
    description: null,
    problems: parseProblems(result.stderr).filter((p) => fileOf(p) === own),
  }
}

export async function previewDraft(
  transport: Transport,
  text: string,
  declared: Declared,
): Promise<Preview> {
  const result = await transport.previewDraft({ ...declared, text })
  return readPreview(declared, result)
}

export interface Mark {
  from: number
  to: number
  severity: 'error' | 'warning'
  message: string
}

// Where each problem that has a place is in the text: from its column to the
// end of the word there, or to the end of the line when there is no word.
export function marksFor(text: string, problems: readonly Problem[]): Mark[] {
  const starts = [0]
  for (let i = 0; i < text.length; i++) if (text[i] === '\n') starts.push(i + 1)
  const marks: Mark[] = []
  for (const problem of problems) {
    if (problem.line === null || problem.column === null) continue
    const lineStart = starts[problem.line - 1]
    if (lineStart === undefined) continue
    const lineEnd = text.indexOf('\n', lineStart)
    const end = lineEnd === -1 ? text.length : lineEnd
    const from = Math.min(lineStart + Math.max(problem.column - 1, 0), end)
    const word = /^[A-Za-z0-9_']+/.exec(text.slice(from, end))
    marks.push({
      from,
      to: Math.max(word ? from + word[0].length : end, from),
      severity: problem.severity,
      message: problem.message,
    })
  }
  return marks
}

// The form the Agent Skills specification gives a skill's name.
export function isSkillName(name: string): boolean {
  return /^[a-z0-9]+(-[a-z0-9]+)*$/.test(name) && name.length <= 64
}

// What is wrong with the text of a new skill: its frontmatter must name it, in
// the form skills have, and say what it is for.
export function skillProblems(text: string): Problem[] {
  const meta = parseSkillMeta(text)
  const problems: string[] = []
  if (meta.name === null) problems.push('the frontmatter has no name')
  else if (!isSkillName(meta.name)) {
    problems.push('the name is 1 to 64 lowercase letters, digits and single hyphens')
  }
  if (meta.description === null) problems.push('the frontmatter has no description')
  return problems.map((message) => ({
    severity: 'error' as const,
    file: null,
    line: null,
    column: null,
    message,
  }))
}

// Whether a name is one a definition's file can have.
export function isDefinitionName(name: string): boolean {
  return /^[A-Za-z][A-Za-z0-9_]*$/.test(name) && name.length <= 128
}

// The text with the name it declares changed, and nothing else changed; the
// text itself when it declares none.
export function renameDeclared(text: string, name: string): string {
  const match = /^((?:\s|--[^\n]*)*(?:Pipeline|System|Agent)\s+)([A-Za-z][A-Za-z0-9_]*)/.exec(text)
  if (match?.[1] === undefined || match[2] === undefined) return text
  return match[1] + name + text.slice(match[0].length)
}

// The text of a skill with the name in its frontmatter changed; the text itself
// when the frontmatter has none.
export function renameSkill(text: string, name: string): string {
  const frontmatter = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text)
  if (frontmatter?.[1] === undefined) return text
  const line = /^(name:[ \t]*)(.*)$/m.exec(frontmatter[1])
  if (line === null) return text
  const at = frontmatter[0].indexOf(frontmatter[1]) + line.index + line[1]!.length
  return text.slice(0, at) + name + text.slice(at + line[2]!.length)
}
