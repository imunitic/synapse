import { describe, expect, it } from 'vitest'
import type { RunEvent } from './executions.ts'
import {
  commonFolder,
  harnessOf,
  mergeSessionLines,
  readActivity,
  readSessionLog,
  replacementDiff,
  sessionsByVisit,
  shownPath,
  unwrapShell,
} from './activity.ts'

const jsonl = (...events: unknown[]) => events.map((e) => JSON.stringify(e)).join('\n')

// A Claude session: it reads a file, writes another, edits it, runs a command that
// fails, and reports its result the way Claude does, through a tool.
const claude = jsonl(
  { type: 'system', subtype: 'hook_started' },
  { type: 'system', subtype: 'init', tools: [] },
  {
    type: 'assistant',
    message: {
      content: [{ type: 'tool_use', id: 't1', name: 'Read', input: { file_path: '/w/notes.txt' } }],
    },
  },
  { type: 'rate_limit_event', rate_limit_info: {} },
  {
    type: 'user',
    message: { content: [{ type: 'tool_result', tool_use_id: 't1', content: '1\tpineapple' }] },
    tool_use_result: { type: 'text', file: {} },
  },
  {
    type: 'assistant',
    message: {
      content: [
        {
          type: 'tool_use',
          id: 't2',
          name: 'Write',
          input: { file_path: '/w/result.txt', content: 'pineapple\n' },
        },
        {
          type: 'tool_use',
          id: 't3',
          name: 'Edit',
          input: { file_path: '/w/result.txt', old_string: 'pineapple', new_string: 'mango' },
        },
        {
          type: 'tool_use',
          id: 't4',
          name: 'Bash',
          input: { command: 'false', description: 'fail' },
        },
      ],
    },
  },
  {
    type: 'user',
    message: {
      content: [{ type: 'tool_result', tool_use_id: 't2', content: 'File created successfully' }],
    },
    tool_use_result: {
      type: 'create',
      filePath: '/w/result.txt',
      content: 'pineapple\n',
      structuredPatch: [],
    },
  },
  {
    type: 'user',
    message: {
      content: [{ type: 'tool_result', tool_use_id: 't3', content: 'The file has been updated' }],
    },
    tool_use_result: {
      structuredPatch: [
        { oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ['-pineapple', '+mango'] },
      ],
    },
  },
  {
    type: 'user',
    message: {
      content: [{ type: 'tool_result', tool_use_id: 't4', content: 'boom', is_error: true }],
    },
  },
  { type: 'assistant', message: { content: [{ type: 'text', text: 'I changed the word.' }] } },
  {
    type: 'assistant',
    message: {
      content: [
        { type: 'tool_use', id: 't5', name: 'StructuredOutput', input: { outcome: 'Done' } },
      ],
    },
  },
  {
    type: 'result',
    is_error: false,
    num_turns: 6,
    duration_ms: 5298,
    total_cost_usd: 0.119,
    usage: {
      input_tokens: 6,
      cache_creation_input_tokens: 100,
      cache_read_input_tokens: 10,
      output_tokens: 133,
    },
  },
)

describe('a Claude session', () => {
  const activity = readActivity(claude)

  it('lists what the agent did, in order, with what each came to', () => {
    expect(activity.harness).toBe('Claude')
    expect(activity.actions.map((a) => [a.kind, a.title, a.target, a.status])).toEqual([
      ['read', 'Read', '/w/notes.txt', 'ok'],
      ['write', 'Wrote', '/w/result.txt', 'ok'],
      ['edit', 'Edited', '/w/result.txt', 'ok'],
      ['command', 'Ran', 'false', 'failed'],
      ['message', 'Said', null, 'ok'],
    ])
  })

  it('shows an edit as its patch and a new file as its lines', () => {
    expect(activity.actions[2]?.detail).toBe('@@ -1,1 +1,1 @@\n-pineapple\n+mango')
    expect(activity.actions[1]?.detail).toBe('+pineapple')
  })

  it('keeps the output of a command that failed', () => {
    expect(activity.actions[3]?.detail).toBe('boom')
  })

  it('leaves out the tool that reports the result', () => {
    expect(activity.actions.some((a) => a.title === 'StructuredOutput')).toBe(false)
  })

  it('lists a file that was changed twice once, as what it was made', () => {
    expect(activity.changes).toEqual([{ path: '/w/result.txt', change: 'add' }])
  })

  it('takes cost, turns, time and tokens from the result', () => {
    expect(activity.stats).toEqual({
      costUsd: 0.119,
      turns: 6,
      durationMs: 5298,
      inputTokens: 116,
      outputTokens: 133,
    })
  })

  it('reads a record that kept only the final result as a session with no actions', () => {
    const old = readActivity(
      JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 0.5, num_turns: 3 }),
    )
    expect(old.harness).toBe('Claude')
    expect(old.actions).toEqual([])
    expect(old.stats.costUsd).toBe(0.5)
  })

  it('shows a session that failed as a failure', () => {
    const failed = readActivity(
      jsonl({ type: 'result', is_error: true, result: 'You have hit your limit' }),
    )
    expect(failed.actions).toEqual([
      {
        kind: 'error',
        title: 'Failed',
        target: null,
        detail: 'You have hit your limit',
        status: 'failed',
      },
    ])
  })
})

const codex = jsonl(
  { type: 'thread.started', thread_id: 'x' },
  { type: 'turn.started' },
  {
    type: 'item.completed',
    item: { id: 'i0', type: 'agent_message', text: 'Looking at the file.' },
  },
  {
    type: 'item.started',
    item: {
      id: 'i1',
      type: 'command_execution',
      command: '/bin/zsh -lc "sed -n \'1,5p\' notes.txt"',
      aggregated_output: '',
      exit_code: null,
      status: 'in_progress',
    },
  },
  {
    type: 'item.completed',
    item: {
      id: 'i1',
      type: 'command_execution',
      command: '/bin/zsh -lc "sed -n \'1,5p\' notes.txt"',
      aggregated_output: 'pineapple\n',
      exit_code: 0,
      status: 'completed',
    },
  },
  {
    type: 'item.completed',
    item: {
      id: 'i2',
      type: 'file_change',
      changes: [
        { path: '/w/result.txt', kind: 'add' },
        { path: '/w/old.txt', kind: 'delete' },
      ],
      status: 'completed',
    },
  },
  {
    type: 'item.completed',
    item: {
      id: 'i3',
      type: 'command_execution',
      command: '/bin/zsh -lc false',
      aggregated_output: '',
      exit_code: 1,
      status: 'completed',
    },
  },
  {
    type: 'item.completed',
    item: { id: 'i4', type: 'agent_message', text: '{"outcome":"Done","summary":"ok","data":{}}' },
  },
  {
    type: 'turn.completed',
    usage: { input_tokens: 100, cached_input_tokens: 50, output_tokens: 7 },
  },
)

describe('a Codex session', () => {
  const activity = readActivity(codex)

  it('lists commands once each, with their output and whether they failed', () => {
    expect(activity.harness).toBe('Codex')
    expect(activity.actions.map((a) => [a.kind, a.title, a.target, a.status])).toEqual([
      ['message', 'Said', null, 'ok'],
      ['command', 'Ran', "sed -n '1,5p' notes.txt", 'ok'],
      ['write', 'Wrote', '/w/result.txt', 'ok'],
      ['edit', 'Deleted', '/w/old.txt', 'ok'],
      ['command', 'Ran', 'false', 'failed'],
    ])
    expect(activity.actions[1]?.detail).toBe('pineapple\n')
  })

  it('lists the files that changed, and leaves out the result message', () => {
    expect(activity.changes).toEqual([
      { path: '/w/result.txt', change: 'add' },
      { path: '/w/old.txt', change: 'delete' },
    ])
    expect(activity.actions.some((a) => a.detail?.includes('"outcome"'))).toBe(false)
  })

  it('has tokens and no cost', () => {
    expect(activity.stats).toMatchObject({ costUsd: null, inputTokens: 100, outputTokens: 7 })
  })

  it('shows a turn that failed', () => {
    const failed = readActivity(
      jsonl({ type: 'thread.started' }, { type: 'turn.failed', error: { message: 'no quota' } }),
    )
    expect(failed.actions[0]).toMatchObject({ kind: 'error', detail: 'no quota' })
  })
})

const part = (type: string, extra: object) => ({
  type,
  timestamp: 1000,
  sessionID: 's',
  part: { type, ...extra },
})

const opencode = jsonl(
  part('step_start', {}),
  {
    ...part('tool_use', {
      tool: 'read',
      state: { status: 'completed', input: { path: 'notes.txt' }, output: 'Read file' },
    }),
    timestamp: 2000,
  },
  {
    ...part('tool_use', {
      tool: 'write',
      state: {
        status: 'completed',
        input: { path: 'result.txt', content: 'pineapple' },
        output: 'Created',
      },
    }),
    timestamp: 3000,
  },
  {
    ...part('tool_use', {
      tool: 'edit',
      state: {
        status: 'completed',
        input: { path: 'result.txt', oldString: 'pineapple', newString: 'mango' },
        output: 'Edited',
      },
    }),
    timestamp: 4000,
  },
  {
    ...part('tool_use', {
      tool: 'shell',
      state: { status: 'error', input: { command: 'false' }, output: 'boom' },
    }),
    timestamp: 5000,
  },
  { ...part('text', { text: '{"outcome":"Done","summary":"x","data":{}}' }), timestamp: 6000 },
  {
    ...part('step_finish', { reason: 'stop', cost: 0.0005, tokens: { input: 900, output: 30 } }),
    timestamp: 7000,
  },
  {
    ...part('step_finish', { reason: 'stop', cost: 0.0003, tokens: { input: 100, output: 20 } }),
    timestamp: 8000,
  },
)

describe('an OpenCode session', () => {
  const activity = readActivity(opencode)

  it('lists the tool calls with their targets and outcomes', () => {
    expect(activity.harness).toBe('Opencode')
    expect(activity.actions.map((a) => [a.kind, a.target, a.status])).toEqual([
      ['read', 'notes.txt', 'ok'],
      ['write', 'result.txt', 'ok'],
      ['edit', 'result.txt', 'ok'],
      ['command', 'false', 'failed'],
    ])
    expect(activity.actions[2]?.detail).toBe('-pineapple\n+mango')
    expect(activity.changes).toEqual([{ path: 'result.txt', change: 'add' }])
  })

  it('sums what each step cost, and takes the time from the first and last events', () => {
    expect(activity.stats.costUsd).toBeCloseTo(0.0008)
    expect(activity.stats).toMatchObject({ inputTokens: 1000, outputTokens: 50, durationMs: 7000 })
  })

  it('shows an error event', () => {
    const failed = readActivity(
      jsonl({
        type: 'error',
        sessionID: 's',
        part: {},
        error: { type: 'provider.rate-limit', message: 'Provider returned error' },
      }),
    )
    expect(failed.actions[0]).toMatchObject({ kind: 'error', detail: 'Provider returned error' })
  })
})

describe('transcripts in general', () => {
  it('knows none it has not seen', () => {
    expect(harnessOf([])).toBe('unknown')
    expect(readActivity('not json\n{"hello":1}')).toMatchObject({ harness: 'unknown', actions: [] })
  })

  it('skips a line that is not JSON in the middle of a session', () => {
    const text = `${jsonl({ type: 'thread.started' })}\nwarning: something\n${jsonl({ type: 'turn.completed', usage: { input_tokens: 1, output_tokens: 2 } })}`
    expect(readActivity(text).stats.outputTokens).toBe(2)
  })

  it('unwraps the shell a command was run through', () => {
    expect(unwrapShell('/bin/zsh -lc "echo \\"hi\\""')).toBe('echo "hi"')
    expect(unwrapShell("bash -c 'ls -la'")).toBe('ls -la')
    expect(unwrapShell('/bin/zsh -lc ls')).toBe('ls')
    expect(unwrapShell('git status')).toBe('git status')
  })

  it('makes a diff of two texts', () => {
    expect(replacementDiff('a\nb', 'c')).toBe('-a\n-b\n+c')
    expect(replacementDiff('', 'x')).toBe('+x')
    expect(replacementDiff('', 'x\n')).toBe('+x')
  })

  it('shows paths without the folder they share', () => {
    const paths = ['/w/a/notes.txt', '/w/a/result.txt', '/w/a/sub/x.txt', 'relative.txt']
    expect(commonFolder(paths)).toBe('/w/a')
    expect(shownPath('/w/a/sub/x.txt', '/w/a')).toBe('sub/x.txt')
    expect(shownPath('relative.txt', '/w/a')).toBe('relative.txt')
    expect(commonFolder(['relative.txt'])).toBe('')
    expect(shownPath('/w/ab/x', '/w/a')).toBe('/w/ab/x')
  })
})

const event = (
  sequence: number,
  kind: string,
  step: string | null,
  detail: unknown = null,
): RunEvent => ({ sequence, kind, step, detail })

describe('sessionsByVisit', () => {
  it('gives each visit the sessions that ended in it, including retries', () => {
    const events = [
      event(1, 'run.started', null),
      event(2, 'step.started', 'A'),
      event(3, 'session.finished', 'A', {
        attempt: 1,
        succeeded: false,
        transcript: '/t/1-A-1.jsonl',
      }),
      event(4, 'session.finished', 'A', {
        attempt: 2,
        succeeded: true,
        transcript: '/t/1-A-2.jsonl',
      }),
      event(5, 'step.finished', 'A', { outcome: 'Done', next: 'B' }),
      event(6, 'step.started', 'B'),
      event(7, 'session.finished', 'B', {
        attempt: 1,
        succeeded: true,
        transcript: '/t/2-B-1.jsonl',
      }),
      event(8, 'session.finished', 'B', { attempt: 1, succeeded: true, transcript: null }),
    ]
    expect(sessionsByVisit(events)).toEqual([
      [
        { attempt: 1, succeeded: false, transcript: '/t/1-A-1.jsonl' },
        { attempt: 2, succeeded: true, transcript: '/t/1-A-2.jsonl' },
      ],
      [
        { attempt: 1, succeeded: true, transcript: '/t/2-B-1.jsonl' },
        { attempt: 1, succeeded: true, transcript: null },
      ],
    ])
  })
})

// A session file of Claude Code: what the person typed, what the model thought
// and said, and each tool call with its result, among lines that are about the
// session and not the conversation.
const claudeSession = jsonl(
  { type: 'permission-mode', permissionMode: 'default' },
  { type: 'user', sessionId: 's', message: { role: 'user', content: 'Fix the bug in a.txt' } },
  { type: 'attachment', attachment: {} },
  {
    type: 'assistant',
    message: { content: [{ type: 'thinking', thinking: 'Let me read the file first.' }] },
  },
  { type: 'assistant', message: { content: [{ type: 'thinking', thinking: '' }] } },
  { type: 'assistant', message: { content: [{ type: 'text', text: 'I will read it.' }] } },
  {
    type: 'assistant',
    message: {
      content: [{ type: 'tool_use', id: 'r1', name: 'Read', input: { file_path: '/w/a.txt' } }],
    },
  },
  {
    type: 'user',
    message: { content: [{ type: 'tool_result', tool_use_id: 'r1', content: '1\tbug' }] },
    toolUseResult: { type: 'text', file: {} },
  },
  {
    type: 'assistant',
    message: {
      content: [
        {
          type: 'tool_use',
          id: 'e1',
          name: 'Edit',
          input: { file_path: '/w/a.txt', old_string: 'bug', new_string: 'fix' },
        },
      ],
    },
  },
  {
    type: 'user',
    message: { content: [{ type: 'tool_result', tool_use_id: 'e1', content: 'updated' }] },
    toolUseResult: {
      structuredPatch: [
        { oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ['-bug', '+fix'] },
      ],
    },
  },
  // A subagent's lines, and what the harness adds, are not the conversation.
  { type: 'user', isSidechain: true, message: { content: 'a subagent was asked this' } },
  {
    type: 'user',
    isMeta: true,
    message: { content: [{ type: 'text', text: '<system-reminder>' }] },
  },
  { type: 'user', message: { content: [{ type: 'text', text: 'Thanks, now run the tests' }] } },
  {
    type: 'assistant',
    message: {
      content: [{ type: 'tool_use', id: 'b1', name: 'Bash', input: { command: 'npm test' } }],
    },
  },
  {
    type: 'user',
    message: {
      content: [{ type: 'tool_result', tool_use_id: 'b1', content: 'boom', is_error: true }],
    },
  },
)

describe('the conversation of a Claude session file', () => {
  const activity = readSessionLog('Claude', claudeSession)

  it('has what was typed, thought, said and done, in order, and nothing of the session around it', () => {
    expect(activity.actions.map((a) => [a.kind, a.title, a.target])).toEqual([
      ['prompt', 'You', null],
      ['thinking', 'Thought', null],
      ['message', 'Said', null],
      ['read', 'Read', '/w/a.txt'],
      ['edit', 'Edited', '/w/a.txt'],
      ['prompt', 'You', null],
      ['command', 'Ran', 'npm test'],
    ])
    expect(activity.actions[0]?.detail).toBe('Fix the bug in a.txt')
    expect(activity.actions[1]?.detail).toBe('Let me read the file first.')
    expect(activity.actions[5]?.detail).toBe('Thanks, now run the tests')
  })

  it('shows an edit as the patch the result carries and a failure as its output', () => {
    expect(activity.actions[4]?.detail).toBe('@@ -1,1 +1,1 @@\n-bug\n+fix')
    expect(activity.actions[6]).toMatchObject({ status: 'failed', detail: 'boom' })
    expect(activity.changes).toEqual([{ path: '/w/a.txt', change: 'update' }])
  })

  it('does not take what a step printed for a conversation: there a user line is not a prompt', () => {
    const printed = jsonl(
      { type: 'user', message: { content: [{ type: 'text', text: 'a notice of the harness' }] } },
      { type: 'result', is_error: false },
    )
    expect(readActivity(printed).actions).toEqual([])
  })
})

// A rollout file of Codex.
const codexRollout = jsonl(
  { type: 'session_meta', payload: { id: 'x', cwd: '/w' } },
  { type: 'event_msg', payload: { type: 'task_started' } },
  {
    type: 'response_item',
    payload: {
      type: 'message',
      role: 'developer',
      content: [{ type: 'input_text', text: 'instructions' }],
    },
  },
  {
    type: 'response_item',
    payload: {
      type: 'message',
      role: 'user',
      content: [{ type: 'input_text', text: '<environment_context>cwd</environment_context>' }],
    },
  },
  {
    type: 'response_item',
    payload: {
      type: 'message',
      role: 'user',
      content: [{ type: 'input_text', text: 'Add a test' }],
    },
  },
  {
    type: 'response_item',
    payload: { type: 'reasoning', summary: [{ text: 'Plan the test' }], encrypted_content: 'x' },
  },
  { type: 'response_item', payload: { type: 'reasoning', summary: [], encrypted_content: 'x' } },
  {
    type: 'response_item',
    payload: {
      type: 'function_call',
      name: 'shell',
      arguments: '{"command":["bash","-lc","ls -la"]}',
      call_id: 'c1',
    },
  },
  {
    type: 'response_item',
    payload: {
      type: 'function_call_output',
      call_id: 'c1',
      output: '{"output":"total 0","metadata":{"exit_code":0}}',
    },
  },
  {
    type: 'response_item',
    payload: {
      type: 'function_call',
      name: 'shell',
      arguments: '{"command":["false"]}',
      call_id: 'c2',
    },
  },
  {
    type: 'response_item',
    payload: {
      type: 'function_call_output',
      call_id: 'c2',
      output: '{"output":"nope","metadata":{"exit_code":1}}',
    },
  },
  {
    type: 'response_item',
    payload: {
      type: 'custom_tool_call',
      name: 'apply_patch',
      call_id: 'p1',
      input: '*** Begin Patch\n*** Add File: t.test.ts\n+test\n*** End Patch',
    },
  },
  {
    type: 'response_item',
    payload: { type: 'custom_tool_call_output', call_id: 'p1', output: 'Success' },
  },
  {
    type: 'response_item',
    payload: { type: 'web_search_call', status: 'completed', action: { query: 'vitest docs' } },
  },
  {
    type: 'response_item',
    payload: {
      type: 'message',
      role: 'assistant',
      content: [{ type: 'output_text', text: 'Added it.' }],
    },
  },
)

describe('the conversation of a Codex rollout', () => {
  const activity = readSessionLog('Codex', codexRollout)

  it('has what was typed, thought, run and said, and leaves out what the harness adds', () => {
    expect(activity.harness).toBe('Codex')
    expect(activity.actions.map((a) => [a.kind, a.title, a.target])).toEqual([
      ['prompt', 'You', null],
      ['thinking', 'Thought', null],
      ['command', 'Ran', 'ls -la'],
      ['command', 'Ran', 'false'],
      ['write', 'Wrote', 't.test.ts'],
      ['search', 'Searched the web', 'vitest docs'],
      ['message', 'Said', null],
    ])
    expect(activity.actions[0]?.detail).toBe('Add a test')
  })

  it('gives a command its output, and a failed exit code as a failure', () => {
    expect(activity.actions[2]).toMatchObject({ status: 'ok', detail: 'total 0' })
    expect(activity.actions[3]).toMatchObject({ status: 'failed', detail: 'nope' })
  })

  it('shows a patch as its text and lists the files it changes', () => {
    expect(activity.actions[4]?.detail).toContain('+test')
    expect(activity.actions[4]?.status).toBe('ok')
    expect(activity.changes).toEqual([{ path: 't.test.ts', change: 'add' }])
  })
})

describe('the conversation of an OpenCode session export', () => {
  // The messages as `opencode session export` lists them.
  const user = {
    id: 'msg_1',
    type: 'user',
    time: { created: 1 },
    text: 'Read hello.txt and say what is in it.\n\n[SYNAPSE-SESSION-START]\n# Synapse Vault as permanent memory\nmore',
    files: [],
  }
  const thinking = { type: 'reasoning', text: 'I should read the file.' }
  const read = {
    type: 'tool',
    id: 'call-1',
    name: 'read',
    state: {
      status: 'completed',
      input: { path: 'hello.txt' },
      content: [{ type: 'text', text: 'Read file hello.txt, lines 1-1\n1: blue green red' }],
    },
  }
  const model = {
    id: 'msg_2',
    type: 'assistant',
    content: [thinking, read],
    cost: 0.004,
    tokens: { input: 100, output: 7 },
  }
  const answer = {
    id: 'msg_3',
    type: 'assistant',
    content: [{ type: 'text', text: 'blue green red' }],
    cost: 0.001,
    tokens: { input: 20, output: 3 },
  }
  const idle = { id: 'msg_4', type: 'idle', outcome: 'succeeded' }
  const log = (...messages: object[]) =>
    readSessionLog('Opencode', messages.map((m) => JSON.stringify(m)).join('\n'))

  it('has what the person typed without what the Synapse plugin adds, then what the model did', () => {
    const activity = log(user, model, answer, idle)
    expect(activity.harness).toBe('Opencode')
    expect(activity.actions.map((a) => [a.kind, a.title])).toEqual([
      ['prompt', 'You'],
      ['thinking', 'Thought'],
      ['read', 'Read'],
      ['message', 'Said'],
    ])
    expect(activity.actions[0]?.detail).toBe('Read hello.txt and say what is in it.')
    expect(activity.actions[1]?.detail).toBe('I should read the file.')
    expect(activity.actions[2]).toMatchObject({ target: 'hello.txt', status: 'ok', detail: null })
    expect(activity.actions[3]?.detail).toBe('blue green red')
  })

  it('adds up the tokens and the cost of the model messages', () => {
    const { stats } = log(user, model, answer, idle)
    expect(stats.inputTokens).toBe(120)
    expect(stats.outputTokens).toBe(10)
    expect(stats.costUsd).toBeCloseTo(0.005)
  })

  it('shows a tool that has not finished as pending, a failed one as failed, with what it printed', () => {
    const running = {
      ...read,
      state: { status: 'running', input: { command: 'make' } },
      name: 'bash',
    }
    const failed = {
      ...read,
      name: 'bash',
      state: {
        status: 'error',
        input: { command: 'make' },
        content: [{ type: 'text', text: 'make: *** error' }],
      },
    }
    const pending = log({ id: 'a', type: 'assistant', content: [running] })
    expect(pending.actions[0]).toMatchObject({ kind: 'command', target: 'make', status: 'pending' })
    const bad = log({ id: 'a', type: 'assistant', content: [failed] })
    expect(bad.actions[0]).toMatchObject({ status: 'failed', detail: 'make: *** error' })
  })

  it('lists the files it wrote and edited as changes', () => {
    const wrote = {
      ...read,
      name: 'write',
      state: { status: 'completed', input: { path: 'a.txt', content: 'x' }, content: [] },
    }
    const edited = {
      ...read,
      name: 'edit',
      state: {
        status: 'completed',
        input: { path: 'b.txt', oldString: 'x', newString: 'y' },
        content: [],
      },
    }
    const activity = log({ id: 'a', type: 'assistant', content: [wrote, edited] })
    expect(activity.changes).toEqual([
      { path: 'a.txt', change: 'add' },
      { path: 'b.txt', change: 'update' },
    ])
  })

  it('has a message that came again once, as it came last, where it first was', () => {
    const early = { id: 'msg_3', type: 'assistant', content: [{ type: 'text', text: 'blue' }] }
    const activity = log(user, early, model, {
      ...early,
      content: [{ type: 'text', text: 'blue green' }],
    })
    expect(activity.actions.map((a) => a.detail)).toEqual([
      'Read hello.txt and say what is in it.',
      'blue green',
      'I should read the file.',
      null,
    ])
  })

  it('finds nothing in lines that are not messages', () => {
    expect(readSessionLog('Opencode', 'nope\n{"id":1}\n\n').actions).toEqual([])
  })
})

describe('mergeSessionLines', () => {
  it('adds the lines of a session file, which only grows', () => {
    expect(mergeSessionLines('Claude', ['a'], ['b', 'c'])).toEqual(['a', 'b', 'c'])
    expect(mergeSessionLines('Codex', [], ['a'])).toEqual(['a'])
  })

  it('replaces an OpenCode message by its id, and adds one that is new', () => {
    const have = ['{"id":"m1","t":"one"}', '{"id":"m2","t":"tw"}']
    const merged = mergeSessionLines('Opencode', have, [
      '{"id":"m2","t":"two"}',
      '{"id":"m3","t":"3"}',
    ])
    expect(merged).toEqual([
      '{"id":"m1","t":"one"}',
      '{"id":"m2","t":"two"}',
      '{"id":"m3","t":"3"}',
    ])
    // What it was given is left as it was.
    expect(have[1]).toBe('{"id":"m2","t":"tw"}')
  })

  it('holds a message that comes twice in one batch once, and keeps a line without an id', () => {
    const merged = mergeSessionLines(
      'Opencode',
      [],
      ['{"id":"m1","t":"a"}', 'not json', '{"id":"m1","t":"b"}'],
    )
    expect(merged).toEqual(['{"id":"m1","t":"b"}', 'not json'])
  })
})
