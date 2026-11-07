// What an agent did in a session, read from the transcript its harness wrote:
// one JSON event per line, in a form that is each harness's own. Every reader
// gives the same list of actions.

import type { RunEvent } from './executions.ts'

// `prompt` and `thinking` come only from a conversation that is followed as it
// goes, not from what a step's session printed.
export type ActionKind =
  | 'read'
  | 'write'
  | 'edit'
  | 'command'
  | 'search'
  | 'message'
  | 'prompt'
  | 'thinking'
  | 'other'
  | 'error'

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

// What a person typed, in the content of a user line that holds no tool result;
// null when it holds none.
function promptText(content: unknown): string | null {
  if (typeof content === 'string') return content.trim() === '' ? null : content
  const parts = list(content).map(obj)
  if (parts.some((p) => p?.type === 'tool_result')) return null
  const texts = parts
    .map((p) => (p?.type === 'text' ? str(p.text) : null))
    .filter((t) => t !== null)
  const text = texts.join('\n')
  return text.trim() === '' ? null : text
}

// `conversation`: the lines are those of a session file, which also holds what
// the person typed and what the model thought, and writes the result of a tool
// as `toolUseResult`.
function readClaude(events: readonly Json[], conversation = false): Activity {
  const actions: Action[] = []
  const changes: FileChange[] = []
  const stats = emptyStats()
  const byId = new Map<string, { action: Action; input: Json; name: string }>()

  for (const event of events) {
    const type = str(event.type)
    // A subagent's own lines, and the context the harness adds, are not the conversation.
    if (conversation && (event.isSidechain === true || event.isMeta === true)) continue
    const content = list(obj(event.message)?.content).map(obj)
    if (type === 'assistant') {
      for (const part of content) {
        if (part === null) continue
        if (conversation && part.type === 'thinking') {
          const thought = str(part.thinking) ?? ''
          if (thought.trim() !== '') {
            actions.push({
              kind: 'thinking',
              title: 'Thought',
              target: null,
              detail: thought,
              status: 'ok',
            })
          }
        } else if (part.type === 'text') {
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
      const outcome = obj(event.tool_use_result) ?? obj(event.toolUseResult)
      if (conversation) {
        const said = promptText(obj(event.message)?.content)
        if (said !== null) {
          actions.push({ kind: 'prompt', title: 'You', target: null, detail: said, status: 'ok' })
        }
      }
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

// ---- A session that is followed as it goes

// The command of a shell tool call, which a harness writes as text, as a list
// of words, or as `bash -lc <script>`.
function commandOf(args: Json): string | null {
  const raw = args.command ?? args.cmd
  if (typeof raw === 'string') return unwrapShell(raw)
  const words = list(raw).filter((w): w is string => typeof w === 'string')
  if (words.length === 0) return null
  const wrapped =
    words.length === 3 &&
    /(?:^|\/)(?:ba|z)?sh$/.test(words[0] ?? '') &&
    /^-l?c$/.test(words[1] ?? '')
  return wrapped ? (words[2] ?? null) : words.join(' ')
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

// The text of an output that is the output itself, or JSON with it in `output`.
function outputText(raw: unknown): { text: string; failed: boolean } {
  if (typeof raw !== 'string') return { text: '', failed: false }
  const parsed = obj(parseJson(raw))
  if (parsed !== null && typeof parsed.output === 'string') {
    const code = num(obj(parsed.metadata)?.exit_code)
    return { text: parsed.output, failed: code !== null && code !== 0 }
  }
  return { text: raw, failed: false }
}

// The files a patch in the form Codex gives names, and what it does to each.
function patchFiles(patch: string): FileChange[] {
  const changes: FileChange[] = []
  for (const match of patch.matchAll(/^\*\*\* (Add|Update|Delete) File: (.+)$/gm)) {
    const how = match[1]
    changes.push({
      path: (match[2] ?? '').trim(),
      change: how === 'Add' ? 'add' : how === 'Delete' ? 'delete' : 'update',
    })
  }
  return changes
}

// What the harness adds to the first message of a session is not what the person
// typed: a line that opens a tag, or the instructions of the project.
function isContext(text: string): boolean {
  const first = text.trimStart()
  return first.startsWith('<') || first.startsWith('# AGENTS.md')
}

// The rollout file of a Codex session: one record for each message, thought, tool
// call and what came of it.
function readCodexRollout(events: readonly Json[]): Activity {
  const actions: Action[] = []
  const changes: FileChange[] = []
  const calls = new Map<string, Action>()

  for (const event of events) {
    if (event.type !== 'response_item') continue
    const item = obj(event.payload)
    if (item === null) continue
    switch (item.type) {
      case 'message': {
        const text = list(item.content)
          .map((part) => str(obj(part)?.text))
          .filter((t) => t !== null)
          .join('\n')
        if (text.trim() === '') break
        if (item.role === 'user' && !isContext(text)) {
          actions.push({ kind: 'prompt', title: 'You', target: null, detail: text, status: 'ok' })
        } else if (item.role === 'assistant') {
          actions.push({ kind: 'message', title: 'Said', target: null, detail: text, status: 'ok' })
        }
        break
      }
      case 'reasoning': {
        const text = list(item.summary)
          .map((part) => str(obj(part)?.text))
          .filter((t) => t !== null)
          .join('\n')
        if (text.trim() !== '') {
          actions.push({
            kind: 'thinking',
            title: 'Thought',
            target: null,
            detail: text,
            status: 'ok',
          })
        }
        break
      }
      case 'function_call': {
        const name = str(item.name) ?? 'tool'
        const args = obj(parseJson(str(item.arguments) ?? '')) ?? {}
        const command = commandOf(args)
        const action: Action = {
          kind: command === null ? 'other' : 'command',
          title: command === null ? name : 'Ran',
          target: command ?? shortJson(args),
          detail: null,
          status: 'pending',
        }
        actions.push(action)
        const id = str(item.call_id)
        if (id !== null) calls.set(id, action)
        break
      }
      case 'custom_tool_call': {
        const name = str(item.name) ?? 'tool'
        const input = str(item.input) ?? ''
        const files = name === 'apply_patch' ? patchFiles(input) : []
        const first = files[0]
        const action: Action =
          name === 'apply_patch'
            ? {
                kind: first?.change === 'add' ? 'write' : 'edit',
                title:
                  first?.change === 'add'
                    ? 'Wrote'
                    : first?.change === 'delete'
                      ? 'Deleted'
                      : 'Edited',
                target: first?.path ?? null,
                detail: input,
                status: 'pending',
              }
            : { kind: 'other', title: name, target: null, detail: input, status: 'pending' }
        actions.push(action)
        changes.push(...files)
        const id = str(item.call_id)
        if (id !== null) calls.set(id, action)
        break
      }
      case 'function_call_output':
      case 'custom_tool_call_output': {
        const action = calls.get(str(item.call_id) ?? '')
        if (action === undefined) break
        const { text, failed } = outputText(item.output)
        action.status = failed ? 'failed' : 'ok'
        // What a patch did is its diff; any other result is its output.
        if (action.kind !== 'edit' && action.kind !== 'write') action.detail = text
        else if (failed) action.detail = text
        break
      }
      case 'web_search_call': {
        const query = str(obj(item.action)?.query)
        actions.push({
          kind: 'search',
          title: 'Searched the web',
          target: query,
          detail: null,
          status: 'ok',
        })
        break
      }
    }
  }
  return { harness: 'Codex', actions, changes: dedupe(changes), stats: emptyStats() }
}

// The conversation of a session file written by Claude Code or by Codex, which
// is followed as the file grows.
export function readSessionLog(harness: 'Claude' | 'Codex', text: string): Activity {
  const events = lines(text)
  return harness === 'Claude' ? readClaude(events, true) : readCodexRollout(events)
}
