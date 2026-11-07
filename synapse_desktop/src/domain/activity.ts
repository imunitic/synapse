// What an agent did in a session, read from the transcript its harness wrote:
// one JSON event per line, in a form that is each harness's own. Every reader
// gives the same list of actions.

import type { RunEvent } from './executions.ts'

export type ActionKind =
  'read' | 'write' | 'edit' | 'command' | 'search' | 'message' | 'other' | 'error'

export interface Action {
  kind: ActionKind
  // What was done, in a word or two: "Read", "Ran", "Edited".
  title: string
  // The file, the command or the pattern it was done to.
  target: string | null
  // What came of it: output, a diff, the text of a message.
  detail: string | null
  status: 'ok' | 'failed' | 'pending'
}

export interface FileChange {
  path: string
  change: 'add' | 'update' | 'delete'
}

export interface SessionStats {
  costUsd: number | null
  inputTokens: number | null
  outputTokens: number | null
  turns: number | null
  durationMs: number | null
}

export type SessionHarness = 'Claude' | 'Codex' | 'Opencode' | 'unknown'

export interface Activity {
  harness: SessionHarness
  actions: Action[]
  changes: FileChange[]
  stats: SessionStats
}

type Json = Record<string, unknown>

function obj(value: unknown): Json | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Json)
    : null
}

function str(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function num(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function list(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function emptyStats(): SessionStats {
  return { costUsd: null, inputTokens: null, outputTokens: null, turns: null, durationMs: null }
}

// A line-by-line diff of two texts: what was there marked `-`, what is there
// now marked `+`. It does not look for what stayed the same.
export function replacementDiff(before: string, after: string): string {
  // The newline that ends the last line does not start another.
  const marked = (text: string, mark: string) =>
    text === ''
      ? []
      : text
          .replace(/\n$/, '')
          .split('\n')
          .map((l) => `${mark}${l}`)
  return [...marked(before, '-'), ...marked(after, '+')].join('\n')
}

// The folder that all the paths are in, so that they can be shown without it.
export function commonFolder(paths: readonly string[]): string {
  const absolute = paths.filter((p) => p.startsWith('/'))
  const first = absolute[0]
  if (first === undefined) return ''
  let folder = first.split('/').slice(0, -1)
  for (const path of absolute.slice(1)) {
    const parts = path.split('/').slice(0, -1)
    let shared = 0
    while (shared < folder.length && shared < parts.length && folder[shared] === parts[shared])
      shared++
    folder = folder.slice(0, shared)
  }
  return folder.join('/')
}

// A path as it is shown: without the folder the whole session worked in.
export function shownPath(path: string, folder: string): string {
  return folder !== '' && path.startsWith(`${folder}/`) ? path.slice(folder.length + 1) : path
}

// A patch in the form Claude gives it: hunks of lines that start with ` `,
// `+` or `-`.
function patchText(patch: unknown): string | null {
  const hunks = list(patch)
    .map(obj)
    .filter((h): h is Json => h !== null)
  if (hunks.length === 0) return null
  return hunks
    .map((h) => {
      const head = `@@ -${num(h.oldStart) ?? 0},${num(h.oldLines) ?? 0} +${num(h.newStart) ?? 0},${num(h.newLines) ?? 0} @@`
      return [head, ...list(h.lines).filter((l): l is string => typeof l === 'string')].join('\n')
    })
    .join('\n')
}

// Whether a message is the result a step reports, which the run shows as its
// outcome.
function isResultEnvelope(text: string): boolean {
  try {
    const parsed = obj(JSON.parse(text))
    return parsed !== null && typeof parsed.outcome === 'string'
  } catch {
    return false
  }
}

function lines(text: string): Json[] {
  const found: Json[] = []
  for (const line of text.split('\n')) {
    if (line.trim() === '') continue
    try {
      const parsed = obj(JSON.parse(line))
      if (parsed !== null) found.push(parsed)
    } catch {
      // A line that is not JSON says nothing about the session.
    }
  }
  return found
}

export function harnessOf(events: readonly Json[]): SessionHarness {
  for (const event of events) {
    const type = str(event.type) ?? ''
    if (type === 'thread.started' || type === 'turn.started' || type.startsWith('item.'))
      return 'Codex'
    if (str(event.sessionID) !== null && obj(event.part) !== null) return 'Opencode'
    if (['system', 'assistant', 'user', 'result', 'rate_limit_event'].includes(type))
      return 'Claude'
  }
  return 'unknown'
}

// ---- Claude

const CLAUDE_KINDS: Record<string, { kind: ActionKind; title: string; field: string }> = {
  Read: { kind: 'read', title: 'Read', field: 'file_path' },
  Write: { kind: 'write', title: 'Wrote', field: 'file_path' },
  Edit: { kind: 'edit', title: 'Edited', field: 'file_path' },
  MultiEdit: { kind: 'edit', title: 'Edited', field: 'file_path' },
  NotebookEdit: { kind: 'edit', title: 'Edited', field: 'notebook_path' },
  Bash: { kind: 'command', title: 'Ran', field: 'command' },
  Grep: { kind: 'search', title: 'Searched', field: 'pattern' },
  Glob: { kind: 'search', title: 'Listed', field: 'pattern' },
}

// The tool that returns a step's result is how Claude reports it; the run shows
// it as the outcome.
const CLAUDE_HIDDEN = new Set(['StructuredOutput'])

function toolOutput(content: unknown): string | null {
  if (typeof content === 'string') return content
  const parts = list(content)
    .map(obj)
    .map((p) => str(p?.text))
    .filter((t): t is string => t !== null)
  return parts.length > 0 ? parts.join('\n') : null
}

function readClaude(events: readonly Json[]): Activity {
  const actions: Action[] = []
  const changes: FileChange[] = []
  const stats = emptyStats()
  const byId = new Map<string, { action: Action; input: Json; name: string }>()

  for (const event of events) {
    const type = str(event.type)
    const content = list(obj(event.message)?.content).map(obj)
    if (type === 'assistant') {
      for (const part of content) {
        if (part === null) continue
        if (part.type === 'text') {
          const text = str(part.text) ?? ''
          if (text.trim() !== '' && !isResultEnvelope(text)) {
            actions.push({
              kind: 'message',
              title: 'Said',
              target: null,
              detail: text,
              status: 'ok',
            })
          }
        } else if (part.type === 'tool_use') {
          const name = str(part.name) ?? 'tool'
          if (CLAUDE_HIDDEN.has(name)) continue
          const input = obj(part.input) ?? {}
          const known = CLAUDE_KINDS[name]
          const action: Action = {
            kind: known?.kind ?? 'other',
            title: known?.title ?? name,
            target: known === undefined ? shortJson(input) : str(input[known.field]),
            detail: null,
            status: 'pending',
          }
          actions.push(action)
          const id = str(part.id)
          if (id !== null) byId.set(id, { action, input, name })
        }
      }
    } else if (type === 'user') {
      const outcome = obj(event.tool_use_result)
      for (const part of content) {
        if (part === null || part.type !== 'tool_result') continue
        const found = byId.get(str(part.tool_use_id) ?? '')
        if (found === undefined) continue
        const { action, input } = found
        action.status = part.is_error === true ? 'failed' : 'ok'
        const output = toolOutput(part.content)
        if (action.kind === 'edit' || action.kind === 'write') {
          const created = outcome?.type === 'create'
          action.detail =
            patchText(outcome?.structuredPatch) ??
            (created
              ? replacementDiff('', str(input.content) ?? str(outcome?.content) ?? '')
              : replacementDiff(str(input.old_string) ?? '', str(input.new_string) ?? ''))
          if (action.status === 'ok' && action.target !== null) {
            changes.push({ path: action.target, change: created ? 'add' : 'update' })
          }
        } else if (action.kind === 'read') {
          action.detail = null
        } else {
          action.detail = output
        }
        if (action.status === 'failed') action.detail = output
      }
    } else if (type === 'result') {
      stats.costUsd = num(event.total_cost_usd)
      stats.turns = num(event.num_turns)
      stats.durationMs = num(event.duration_ms)
      const usage = obj(event.usage)
      if (usage !== null) {
        stats.inputTokens =
          (num(usage.input_tokens) ?? 0) +
          (num(usage.cache_creation_input_tokens) ?? 0) +
          (num(usage.cache_read_input_tokens) ?? 0)
        stats.outputTokens = num(usage.output_tokens)
      }
      if (event.is_error === true) {
        actions.push({
          kind: 'error',
          title: 'Failed',
          target: null,
          detail: str(event.result) ?? str(event.subtype),
          status: 'failed',
        })
      }
    }
  }
  return { harness: 'Claude', actions, changes: dedupe(changes), stats }
}

// ---- Codex

// The command inside the shell Codex runs it through: `/bin/zsh -lc "ls -la"`,
// or `/bin/zsh -lc ls` when it needs no quotes.
export function unwrapShell(command: string): string {
  const match = /^\S*(?:sh|bash|zsh)\s+-l?c\s+([\s\S]+)$/.exec(command.trim())
  const inner = match?.[1]
  if (inner === undefined) return command
  const quote = inner[0]
  if ((quote === '"' || quote === "'") && inner.length > 1 && inner.endsWith(quote)) {
    const body = inner.slice(1, -1)
    return quote === '"' ? body.replace(/\\(["\\$`])/g, '$1') : body
  }
  return inner
}

function readCodex(events: readonly Json[]): Activity {
  const actions: Action[] = []
  const changes: FileChange[] = []
  const stats = emptyStats()
  const byId = new Map<string, Action>()

  for (const event of events) {
    const type = str(event.type)
    const item = obj(event.item)
    if ((type === 'item.started' || type === 'item.completed') && item !== null) {
      const id = str(item.id) ?? ''
      const finished = type === 'item.completed'
      const kind = str(item.type)
      if (kind === 'agent_message') {
        const text = str(item.text) ?? ''
        if (finished && text.trim() !== '' && !isResultEnvelope(text)) {
          actions.push({ kind: 'message', title: 'Said', target: null, detail: text, status: 'ok' })
        }
      } else if (kind === 'command_execution') {
        let action = byId.get(id)
        if (action === undefined) {
          action = {
            kind: 'command',
            title: 'Ran',
            target: unwrapShell(str(item.command) ?? ''),
            detail: null,
            status: 'pending',
          }
          byId.set(id, action)
          actions.push(action)
        }
        if (finished) {
          const code = num(item.exit_code)
          action.status = code === null || code === 0 ? 'ok' : 'failed'
          action.detail = str(item.aggregated_output)
        }
      } else if (kind === 'file_change' && finished) {
        for (const change of list(item.changes).map(obj)) {
          const path = str(change?.path)
          if (path === null) continue
          const how = str(change?.kind)
          const mapped = how === 'add' ? 'add' : how === 'delete' ? 'delete' : 'update'
          actions.push({
            kind: mapped === 'add' ? 'write' : 'edit',
            title: mapped === 'add' ? 'Wrote' : mapped === 'delete' ? 'Deleted' : 'Edited',
            target: path,
            detail: null,
            status: str(item.status) === 'failed' ? 'failed' : 'ok',
          })
          changes.push({ path, change: mapped })
        }
      } else if (finished && kind !== null && kind !== 'reasoning') {
        actions.push({
          kind: 'other',
          title: kind,
          target: null,
          detail: shortJson(item),
          status: 'ok',
        })
      }
    } else if (type === 'turn.completed') {
      const usage = obj(event.usage)
      stats.inputTokens = (stats.inputTokens ?? 0) + (num(usage?.input_tokens) ?? 0)
      stats.outputTokens = (stats.outputTokens ?? 0) + (num(usage?.output_tokens) ?? 0)
    } else if (type === 'turn.failed' || type === 'error') {
      const message = str(obj(event.error)?.message) ?? str(event.message)
      actions.push({
        kind: 'error',
        title: 'Failed',
        target: null,
        detail: message,
        status: 'failed',
      })
    }
  }
  return { harness: 'Codex', actions, changes: dedupe(changes), stats }
}

// ---- OpenCode

const OPENCODE_KINDS: Record<string, { kind: ActionKind; title: string; fields: string[] }> = {
  read: { kind: 'read', title: 'Read', fields: ['path', 'filePath'] },
  write: { kind: 'write', title: 'Wrote', fields: ['path', 'filePath'] },
  edit: { kind: 'edit', title: 'Edited', fields: ['path', 'filePath'] },
  patch: { kind: 'edit', title: 'Edited', fields: ['path', 'filePath'] },
  shell: { kind: 'command', title: 'Ran', fields: ['command'] },
  bash: { kind: 'command', title: 'Ran', fields: ['command'] },
  grep: { kind: 'search', title: 'Searched', fields: ['pattern'] },
  glob: { kind: 'search', title: 'Listed', fields: ['pattern'] },
}

function firstString(input: Json, fields: readonly string[]): string | null {
  for (const field of fields) {
    const value = str(input[field])
    if (value !== null) return value
  }
  return null
}

function readOpencode(events: readonly Json[]): Activity {
  const actions: Action[] = []
  const changes: FileChange[] = []
  const stats = emptyStats()
  let first: number | null = null
  let last: number | null = null

  for (const event of events) {
    const type = str(event.type)
    const part = obj(event.part)
    const at = num(event.timestamp)
    if (at !== null) {
      first ??= at
      last = at
    }
    if (type === 'text' && part !== null) {
      const text = str(part.text) ?? ''
      if (text.trim() !== '' && !isResultEnvelope(text)) {
        actions.push({ kind: 'message', title: 'Said', target: null, detail: text, status: 'ok' })
      }
    } else if (type === 'tool_use' && part !== null) {
      const name = str(part.tool) ?? 'tool'
      const state = obj(part.state) ?? {}
      const input = obj(state.input) ?? {}
      const known = OPENCODE_KINDS[name]
      const status = str(state.status)
      const action: Action = {
        kind: known?.kind ?? 'other',
        title: known?.title ?? name,
        target: known === undefined ? shortJson(input) : firstString(input, known.fields),
        detail: str(state.output),
        status: status === 'completed' ? 'ok' : status === 'error' ? 'failed' : 'pending',
      }
      if (action.kind === 'write') {
        action.detail = replacementDiff('', str(input.content) ?? '')
      } else if (action.kind === 'edit') {
        action.detail = replacementDiff(
          str(input.oldString) ?? str(input.old_string) ?? '',
          str(input.newString) ?? str(input.new_string) ?? '',
        )
      } else if (action.kind === 'read') {
        action.detail = null
      }
      actions.push(action)
      if (action.status === 'ok' && action.target !== null) {
        if (action.kind === 'write') changes.push({ path: action.target, change: 'add' })
        else if (action.kind === 'edit') changes.push({ path: action.target, change: 'update' })
      }
    } else if (type === 'step_finish' && part !== null) {
      const tokens = obj(part.tokens)
      stats.inputTokens = (stats.inputTokens ?? 0) + (num(tokens?.input) ?? 0)
      stats.outputTokens = (stats.outputTokens ?? 0) + (num(tokens?.output) ?? 0)
      const cost = num(part.cost)
      if (cost !== null) stats.costUsd = (stats.costUsd ?? 0) + cost
    } else if (type === 'error') {
      const error = obj(event.error)
      actions.push({
        kind: 'error',
        title: 'Failed',
        target: null,
        detail: str(error?.message) ?? str(error?.type),
        status: 'failed',
      })
    }
  }
  if (first !== null && last !== null) stats.durationMs = last - first
  return { harness: 'Opencode', actions, changes: dedupe(changes), stats }
}

// ---- Shared

function shortJson(value: unknown): string {
  const text = JSON.stringify(value) ?? ''
  return text.length > 200 ? `${text.slice(0, 200)}…` : text
}

// A file that is changed twice is listed once, as what the first change made of it.
function dedupe(changes: readonly FileChange[]): FileChange[] {
  const seen = new Map<string, FileChange>()
  for (const change of changes) if (!seen.has(change.path)) seen.set(change.path, change)
  return [...seen.values()]
}

// The activity in a transcript, whichever harness wrote it. A transcript that
// is not in a form this knows has no actions.
export function readActivity(text: string): Activity {
  const events = lines(text)
  switch (harnessOf(events)) {
    case 'Claude':
      return readClaude(events)
    case 'Codex':
      return readCodex(events)
    case 'Opencode':
      return readOpencode(events)
    case 'unknown':
      return { harness: 'unknown', actions: [], changes: [], stats: emptyStats() }
  }
}

export interface RecordedSession {
  attempt: number
  succeeded: boolean
  // Null for a session that wrote none, such as a scripted run's.
  transcript: string | null
}

// The sessions of each visit to a step, in the order of the visits: a try is
// recorded when it ends, under the visit that is going on.
export function sessionsByVisit(events: readonly RunEvent[]): RecordedSession[][] {
  const visits: RecordedSession[][] = []
  for (const event of events) {
    if (event.kind === 'step.started') {
      visits.push([])
    } else if (event.kind === 'session.finished') {
      const detail = obj(event.detail)
      const transcript = str(detail?.transcript)
      const current = visits.at(-1)
      if (current !== undefined) {
        current.push({
          attempt: num(detail?.attempt) ?? current.length + 1,
          succeeded: detail?.succeeded === true,
          transcript,
        })
      }
    }
  }
  return visits
}
