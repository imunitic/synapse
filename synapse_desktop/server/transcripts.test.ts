import { appendFile, mkdir, mkdtemp, rm, utimes, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { changedMessages, watchTranscripts, type Source, type Watcher } from './transcripts.ts'

let dir: string
let home: string
let sessions: string
let sources: Source[]
let lines: Record<string, string[]>
let watcher: Watcher

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'synapse-desktop-transcripts-'))
  home = join(dir, 'home')
  sessions = join(dir, 'sessions')
  await mkdir(sessions, { recursive: true })
  sources = []
  lines = {}
  watcher = watchTranscripts({
    dir: sessions,
    home,
    intervalMs: 1_000_000,
    events: {
      onSource: (source) => sources.push(source),
      onLines: (id, batch) => {
        lines[id] = [...(lines[id] ?? []), ...batch]
      },
    },
  })
})

afterEach(async () => {
  watcher.stop()
  await rm(dir, { recursive: true, force: true })
})

async function register(name: string, registration: Record<string, unknown>): Promise<void> {
  await writeFile(join(sessions, name), JSON.stringify(registration))
}

const claudeFile = (id: string, project = '-work') =>
  join(home, '.claude', 'projects', project, `${id}.jsonl`)

describe('a Claude session', () => {
  const registration = (id: string) => ({
    harness: 'claude',
    sessionId: id,
    cwd: '/work',
    startedAt: Date.now(),
  })

  it('is made known when it is registered, and followed once its file is there', async () => {
    await register('claude-a.json', registration('aaa'))
    await watcher.poll()
    expect(sources).toEqual([{ id: 'aaa', harness: 'Claude', cwd: '/work' }])
    expect(lines).toEqual({})

    // The file of a session begins when the first prompt is sent.
    await mkdir(join(claudeFile('aaa'), '..'), { recursive: true })
    await writeFile(claudeFile('aaa'), '{"n":1}\n{"n":2}\n')
    await watcher.poll()
    expect(lines.aaa).toEqual(['{"n":1}', '{"n":2}'])
  })

  it('passes on only what was appended, and waits for the end of a line that is half written', async () => {
    await register('claude-a.json', registration('aaa'))
    await mkdir(join(claudeFile('aaa'), '..'), { recursive: true })
    await writeFile(claudeFile('aaa'), '{"n":1}\n{"n"')
    await watcher.poll()
    expect(lines.aaa).toEqual(['{"n":1}'])

    await appendFile(claudeFile('aaa'), ':2}\n{"n":3}\n')
    await watcher.poll()
    expect(lines.aaa).toEqual(['{"n":1}', '{"n":2}', '{"n":3}'])

    await watcher.poll()
    expect(lines.aaa).toHaveLength(3)
  })

  it('finds the file in whichever project folder it is, and does not mix two sessions up', async () => {
    await register('claude-a.json', registration('aaa'))
    await register('claude-b.json', registration('bbb'))
    await mkdir(join(claudeFile('aaa', '-one'), '..'), { recursive: true })
    await mkdir(join(claudeFile('bbb', '-two'), '..'), { recursive: true })
    await writeFile(claudeFile('aaa', '-one'), '{"from":"a"}\n')
    await writeFile(claudeFile('bbb', '-two'), '{"from":"b"}\n')
    await watcher.poll()
    expect(lines).toEqual({ aaa: ['{"from":"a"}'], bbb: ['{"from":"b"}'] })
  })

  it('uses the folder a registration names for Claude', async () => {
    const elsewhere = join(dir, 'config')
    await register('claude-a.json', { ...registration('aaa'), configDir: elsewhere })
    await mkdir(join(elsewhere, 'projects', '-w'), { recursive: true })
    await writeFile(join(elsewhere, 'projects', '-w', 'aaa.jsonl'), '{"ok":true}\n')
    await watcher.poll()
    expect(lines.aaa).toEqual(['{"ok":true}'])
  })

  it('reads a file that was replaced from its start', async () => {
    await register('claude-a.json', registration('aaa'))
    await mkdir(join(claudeFile('aaa'), '..'), { recursive: true })
    await writeFile(claudeFile('aaa'), '{"n":1}\n{"n":2}\n{"n":3}\n')
    await watcher.poll()
    await writeFile(claudeFile('aaa'), '{"n":9}\n')
    await watcher.poll()
    expect(lines.aaa).toEqual(['{"n":1}', '{"n":2}', '{"n":3}', '{"n":9}'])
  })
})

describe('a Codex session', () => {
  const now = Date.now()
  const registration = (cwd = '/work') => ({ harness: 'codex', cwd, startedAt: now })
  const rollout = (day: string, name: string) =>
    join(home, '.codex', 'sessions', '2026', '11', day, `rollout-${name}.jsonl`)

  async function rolloutFile(
    day: string,
    name: string,
    cwd: string,
    mtime = now + 1000,
  ): Promise<string> {
    const file = rollout(day, name)
    await mkdir(join(file, '..'), { recursive: true })
    await writeFile(file, `${JSON.stringify({ type: 'session_meta', payload: { cwd } })}\n`)
    await utimes(file, mtime / 1000, mtime / 1000)
    return file
  }

  it('is the rollout file that began where and when the run did', async () => {
    const wrong = await rolloutFile('07', 'wrong', '/elsewhere')
    const old = await rolloutFile('07', 'old', '/work', now - 600_000)
    const mine = await rolloutFile('07', 'mine', '/work')
    await register('codex-1.json', registration())
    await watcher.poll()
    expect(sources).toEqual([{ id: 'codex-1', harness: 'Codex', cwd: '/work' }])
    expect(lines['codex-1']).toEqual([
      JSON.stringify({ type: 'session_meta', payload: { cwd: '/work' } }),
    ])

    await appendFile(mine, '{"type":"response_item"}\n')
    await appendFile(wrong, '{"x":1}\n')
    await appendFile(old, '{"x":2}\n')
    await watcher.poll()
    expect(lines['codex-1']).toHaveLength(2)
    expect(lines['codex-1']?.[1]).toBe('{"type":"response_item"}')
  })

  it('gives two runs in one folder a file each', async () => {
    await rolloutFile('07', 'first', '/work', now + 1000)
    await rolloutFile('07', 'second', '/work', now + 2000)
    await register('codex-1.json', registration())
    await watcher.poll()
    await register('codex-2.json', registration())
    await watcher.poll()
    expect(Object.keys(lines).sort()).toEqual(['codex-1', 'codex-2'])
    expect(lines['codex-1']).toHaveLength(1)
    expect(lines['codex-2']).toHaveLength(1)
  })

  it('waits for a file that is not there yet', async () => {
    await register('codex-1.json', registration())
    await watcher.poll()
    expect(lines).toEqual({})
    await rolloutFile('07', 'late', '/work')
    await watcher.poll()
    expect(lines['codex-1']).toHaveLength(1)
  })
})

describe('registrations', () => {
  it('are read once, a file that is not one is ignored, and a run the server knows is followed too', async () => {
    await register('claude-a.json', {
      harness: 'claude',
      sessionId: 'aaa',
      cwd: '/w',
      startedAt: 1,
    })
    await writeFile(join(sessions, 'notes.json'), 'not json')
    await register('other.json', { harness: 'gemini', cwd: '/w', startedAt: 1 })
    await register('.hidden.json', { harness: 'claude', sessionId: 'hhh', cwd: '/w', startedAt: 1 })
    await watcher.poll()
    await watcher.poll()
    expect(sources).toEqual([{ id: 'aaa', harness: 'Claude', cwd: '/work'.replace('work', 'w') }])

    watcher.register('direct', { harness: 'claude', sessionId: 'ddd', cwd: '/d', startedAt: 1 })
    expect(sources.at(-1)).toEqual({ id: 'direct', harness: 'Claude', cwd: '/d' })
    await mkdir(join(claudeFile('ddd'), '..'), { recursive: true })
    await writeFile(claudeFile('ddd'), '{"d":1}\n')
    await watcher.poll()
    expect(lines.direct).toEqual(['{"d":1}'])
  })

  it('passes lines on in batches that are not too big', async () => {
    watcher.register('big', { harness: 'claude', sessionId: 'big', cwd: '/d', startedAt: 1 })
    await mkdir(join(claudeFile('big'), '..'), { recursive: true })
    const batches: number[] = []
    watcher.stop()
    watcher = watchTranscripts({
      dir: sessions,
      home,
      intervalMs: 1_000_000,
      events: { onSource: () => undefined, onLines: (_id, batch) => batches.push(batch.length) },
    })
    watcher.register('big', { harness: 'claude', sessionId: 'big', cwd: '/d', startedAt: 1 })
    await writeFile(
      claudeFile('big'),
      Array.from({ length: 450 }, (_, i) => `{"n":${i}}`).join('\n') + '\n',
    )
    await watcher.poll()
    expect(batches).toEqual([200, 200, 50])
  })
})

describe('an OpenCode session', () => {
  const message = (id: string, content: unknown) => ({ id, type: 'assistant', content })
  const exported = (...messages: object[]) => JSON.stringify({ info: {}, messages })

  // A watcher that is given the export to read, and counts how often it is asked.
  function following(answers: (string | null)[], exportEveryMs = 0) {
    let asked = 0
    const sent: Record<string, string[]> = {}
    watcher.stop()
    watcher = watchTranscripts({
      dir: sessions,
      home,
      intervalMs: 1_000_000,
      exportEveryMs,
      exportSession: (_registration, id) => {
        expect(id).toBe('ses_one')
        const answer = answers[Math.min(asked, answers.length - 1)] ?? null
        asked += 1
        return Promise.resolve(answer)
      },
      events: {
        onSource: (source) => sources.push(source),
        onLines: (id, batch) => {
          sent[id] = [...(sent[id] ?? []), ...batch]
        },
      },
    })
    watcher.register('ses_one', {
      harness: 'opencode',
      sessionId: 'ses_one',
      cwd: '/w',
      startedAt: 1,
    })
    return { sent, asked: () => asked }
  }

  it('is made known as OpenCode, and has its messages sent as they come', async () => {
    const first = message('m1', [{ type: 'text', text: 'one' }])
    const second = message('m2', [{ type: 'text', text: 'two' }])
    const { sent } = following([exported(first), exported(first, second)])
    expect(sources).toEqual([{ id: 'ses_one', harness: 'Opencode', cwd: '/w' }])

    await watcher.poll()
    expect(sent.ses_one).toEqual([JSON.stringify(first)])
    await watcher.poll()
    // Only the message that is new.
    expect(sent.ses_one).toEqual([JSON.stringify(first), JSON.stringify(second)])
  })

  it('sends a message again, whole, when it has changed, and not when it has not', async () => {
    const early = message('m1', [{ type: 'text', text: 'Hel' }])
    const later = message('m1', [{ type: 'text', text: 'Hello there' }])
    const { sent } = following([exported(early), exported(early), exported(later)])
    await watcher.poll()
    await watcher.poll()
    expect(sent.ses_one).toEqual([JSON.stringify(early)])
    await watcher.poll()
    expect(sent.ses_one).toEqual([JSON.stringify(early), JSON.stringify(later)])
  })

  it('waits for the session to be there, and for what it cannot read', async () => {
    const first = message('m1', [{ type: 'text', text: 'one' }])
    const { sent } = following([null, 'not json', '{"messages": 3}', exported(first)])
    for (let i = 0; i < 3; i += 1) await watcher.poll()
    expect(sent).toEqual({})
    await watcher.poll()
    expect(sent.ses_one).toEqual([JSON.stringify(first)])
  })

  it('does not run the export more often than it is allowed to', async () => {
    const { asked } = following([exported()], 60_000)
    await watcher.poll()
    await watcher.poll()
    await watcher.poll()
    expect(asked()).toBe(1)
  })
})

describe('changedMessages', () => {
  it('lists the messages that are new or differ, in the order of the export, by the id they have', () => {
    const sent = new Map<string, string>()
    const a = { id: 'a', n: 1 }
    const b = { id: 'b', n: 1 }
    expect(changedMessages(JSON.stringify({ messages: [a, b] }), sent)).toEqual([
      JSON.stringify(a),
      JSON.stringify(b),
    ])
    expect(
      changedMessages(JSON.stringify({ messages: [a, { ...b, n: 2 }, { id: 'c' }] }), sent),
    ).toEqual([JSON.stringify({ ...b, n: 2 }), JSON.stringify({ id: 'c' })])
  })

  it('leaves out what has no id, and finds nothing in what is not an export', () => {
    expect(changedMessages('{"messages":[{"x":1},"y",null]}', new Map())).toEqual([])
    expect(changedMessages('nope', new Map())).toEqual([])
    expect(changedMessages('{"messages":"no"}', new Map())).toEqual([])
  })
})
