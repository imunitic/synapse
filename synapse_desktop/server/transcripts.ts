// Following the conversation of a harness that runs in a terminal: its session
// file grows as the session goes, and what is appended is passed on. A run is
// made known by a registration, one small JSON file in a folder of the
// terminal's own, which a wrapper command or this server writes when it starts
// the harness.

import { open, readFile, readdir, stat } from 'node:fs/promises'
import { join } from 'node:path'
import { z } from 'zod'

export interface Source {
  id: string
  harness: 'Claude' | 'Codex'
  cwd: string
}

export interface TranscriptEvents {
  onSource(source: Source): void
  // Complete lines of a session file, in order, as they were appended.
  onLines(id: string, lines: string[]): void
}

const registrationSchema = z.object({
  harness: z.enum(['claude', 'codex']),
  // Claude: the id the run was started with, which names its file.
  sessionId: z.string().optional(),
  cwd: z.string(),
  // Where the harness keeps its files: the folder of Claude, the home of Codex.
  configDir: z.string().optional(),
  home: z.string().optional(),
  // Epoch milliseconds.
  startedAt: z.number(),
})

export type Registration = z.infer<typeof registrationSchema>

export interface Watcher {
  // Looks at the folder and at the files once.
  poll(): Promise<void>
  // Adds a run that is known by the server and not by a file.
  register(id: string, registration: Registration): void
  stop(): void
}

interface Follow {
  id: string
  registration: Registration
  file: string | null
  offset: number
  // The part of a last line that is not finished.
  partial: string
}

const MAX_LINES = 200
const MAX_CHARS = 512 * 1024
// A session file written a little before the registration still belongs to it.
const SLACK_MS = 2000

async function isFile(path: string): Promise<boolean> {
  return (await stat(path).catch(() => null))?.isFile() ?? false
}

// The file of a Claude session: `<config>/projects/<folder of the project>/<id>.jsonl`,
// in whichever folder it is.
async function claudeFile(registration: Registration, defaultHome: string): Promise<string | null> {
  const id = registration.sessionId
  if (id === undefined) return null
  const projects = join(registration.configDir ?? join(defaultHome, '.claude'), 'projects')
  for (const folder of await readdir(projects).catch(() => [])) {
    const file = join(projects, folder, `${id}.jsonl`)
    if (await isFile(file)) return file
  }
  return null
}

async function firstLine(path: string): Promise<string> {
  const handle = await open(path, 'r')
  try {
    const buffer = Buffer.alloc(64 * 1024)
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0)
    return buffer.toString('utf8', 0, bytesRead).split('\n')[0] ?? ''
  } finally {
    await handle.close()
  }
}

// The newest day folders of the sessions of a Codex home, as paths.
async function recentDays(sessions: string): Promise<string[]> {
  const days: string[] = []
  const sorted = async (dir: string) =>
    (await readdir(dir).catch(() => []))
      .filter((n) => /^\d+$/.test(n))
      .sort()
      .reverse()
  for (const year of await sorted(sessions)) {
    for (const month of await sorted(join(sessions, year))) {
      for (const day of await sorted(join(sessions, year, month))) {
        days.push(join(sessions, year, month, day))
        if (days.length >= 3) return days
      }
    }
  }
  return days
}

// The rollout file of a Codex session that started where and when the run did,
// and that no other run has.
async function codexFile(
  registration: Registration,
  defaultHome: string,
  taken: ReadonlySet<string>,
): Promise<string | null> {
  const sessions = join(registration.home ?? join(defaultHome, '.codex'), 'sessions')
  const found: { file: string; time: number }[] = []
  for (const day of await recentDays(sessions)) {
    for (const name of await readdir(day).catch(() => [])) {
      if (!name.startsWith('rollout-') || !name.endsWith('.jsonl')) continue
      const file = join(day, name)
      if (taken.has(file)) continue
      const info = await stat(file).catch(() => null)
      if (info === null || info.mtimeMs < registration.startedAt - SLACK_MS) continue
      try {
        const meta = JSON.parse(await firstLine(file)) as { payload?: { cwd?: unknown } }
        if (meta.payload?.cwd === registration.cwd) found.push({ file, time: info.birthtimeMs })
      } catch {
        // A file that is not begun is looked at again.
      }
    }
  }
  return found.sort((a, b) => a.time - b.time)[0]?.file ?? null
}

// New complete lines of the file after `offset`, and where the next read starts.
async function readMore(file: string, follow: Follow): Promise<{ lines: string[]; size: number }> {
  const info = await stat(file)
  if (info.size < follow.offset) {
    // The file is shorter than it was: it was replaced, and is read from its start.
    follow.offset = 0
    follow.partial = ''
  }
  if (info.size === follow.offset) return { lines: [], size: info.size }
  const handle = await open(file, 'r')
  try {
    const buffer = Buffer.alloc(info.size - follow.offset)
    await handle.read(buffer, 0, buffer.length, follow.offset)
    const text = follow.partial + buffer.toString('utf8')
    const parts = text.split('\n')
    follow.partial = parts.pop() ?? ''
    return { lines: parts.filter((line) => line.trim() !== ''), size: info.size }
  } finally {
    await handle.close()
  }
}

function batches(lines: readonly string[]): string[][] {
  const result: string[][] = []
  let current: string[] = []
  let chars = 0
  for (const line of lines) {
    if (current.length > 0 && (current.length >= MAX_LINES || chars + line.length > MAX_CHARS)) {
      result.push(current)
      current = []
      chars = 0
    }
    current.push(line)
    chars += line.length
  }
  if (current.length > 0) result.push(current)
  return result
}

export function watchTranscripts(options: {
  // The folder the registrations are written in.
  dir: string
  // The home folder of the user, where harnesses keep what a registration does not name.
  home: string
  events: TranscriptEvents
  intervalMs?: number
}): Watcher {
  const follows: Follow[] = []
  const seen = new Set<string>()
  let running = false
  let stopped = false

  function add(id: string, registration: Registration) {
    follows.push({ id, registration, file: null, offset: 0, partial: '' })
    options.events.onSource({
      id,
      harness: registration.harness === 'claude' ? 'Claude' : 'Codex',
      cwd: registration.cwd,
    })
  }

  async function readRegistrations() {
    for (const name of await readdir(options.dir).catch(() => [])) {
      if (!name.endsWith('.json') || name.startsWith('.') || seen.has(name)) continue
      seen.add(name)
      try {
        const registration = registrationSchema.parse(
          JSON.parse(await readFile(join(options.dir, name), 'utf8')),
        )
        add(registration.sessionId ?? name.slice(0, -'.json'.length), registration)
      } catch {
        // A file that is not a registration says nothing.
      }
    }
  }

  async function poll() {
    if (running || stopped) return
    running = true
    try {
      await readRegistrations()
      for (const follow of follows) {
        if (stopped) return
        if (follow.file === null) {
          const taken = new Set(follows.flatMap((f) => (f.file === null ? [] : [f.file])))
          follow.file =
            follow.registration.harness === 'claude'
              ? await claudeFile(follow.registration, options.home)
              : await codexFile(follow.registration, options.home, taken)
          if (follow.file === null) continue
        }
        const read = await readMore(follow.file, follow).catch(() => null)
        if (read === null) continue
        // The offset is where this read ended, the part of a line that is not finished apart.
        follow.offset = read.size
        const { lines } = read
        if (lines.length === 0) continue
        for (const batch of batches(lines)) options.events.onLines(follow.id, batch)
      }
    } finally {
      running = false
    }
  }

  const timer = setInterval(() => void poll(), options.intervalMs ?? 300)
  return {
    poll,
    register: (id, registration) => add(id, registration),
    stop: () => {
      stopped = true
      clearInterval(timer)
    },
  }
}
