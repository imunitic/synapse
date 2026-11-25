// How much of Claude's limits is used, read from the text `claude -p /usage --output-format json`
// prints. That text is not a promised interface, so a wording that does not match gives
// `unavailable`, never a wrong number. The Rust host reads it alike in
// `src-tauri/src/usage_claude.rs`, and both are tested on the same fixtures.

import { execFile } from 'node:child_process'
import type { UsageReading, UsageWindow } from '../shared/usage.ts'

const WINDOW_LINE = /^(.+?): (\d+(?:\.\d+)?)% used · resets (.+) \(([^)]+)\)$/
const RESET_TEXT = /^(?:([A-Z][a-z]{2}) (\d{1,2}) at )?(\d{1,2})(?::(\d{2}))?(am|pm)$/
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

// The windows that count toward the bar item's colour and figure.
const DECIDING = new Set(['Current session', 'Current week (all models)'])

// The arguments Claude is run with, and how long a read may take; one takes about 4 seconds.
export const CLAUDE_USAGE_ARGS = ['-p', '/usage', '--output-format', 'json']
export const CLAUDE_USAGE_TIMEOUT_MS = 30_000

export interface ClaudeUsageDeps {
  findProgram: (name: string) => Promise<string | null>
  run: (
    program: string,
    args: string[],
    options: { cwd: string; timeoutMs: number },
  ) => Promise<{ code: number; stdout: string; stderr: string }>
  workDir: () => Promise<string>
  now: () => Date
}

// Claude's usage, read now. No process is started when `claude` is not on PATH, and the person's
// Claude settings are neither read nor written: the program itself answers.
export async function readClaudeUsage(deps: ClaudeUsageDeps): Promise<UsageReading> {
  const program = await deps.findProgram('claude')
  if (program === null) return { ...unavailable('claude is not on PATH'), state: 'not-installed' }
  let output: { code: number; stdout: string; stderr: string }
  try {
    output = await deps.run(program, CLAUDE_USAGE_ARGS, {
      cwd: await deps.workDir(),
      timeoutMs: CLAUDE_USAGE_TIMEOUT_MS,
    })
  } catch (error) {
    return unavailable(`claude /usage: ${error instanceof Error ? error.message : String(error)}`)
  }
  if (output.code !== 0) {
    const said = output.stderr
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find((line) => line !== '')
    const exited = `claude /usage exited with code ${output.code}`
    return unavailable(said === undefined ? exited : `${exited}: ${said}`)
  }
  return parseClaudeUsage(output.stdout, deps.now())
}

// Runs a program with nothing on stdin, in `cwd`; rejects when it cannot be started or takes
// longer than `timeoutMs`.
export function runProgram(
  program: string,
  args: string[],
  options: { cwd: string; timeoutMs: number },
): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = execFile(
      program,
      args,
      { cwd: options.cwd, timeout: options.timeoutMs, maxBuffer: 4 * 1024 * 1024 },
      (error, stdout, stderr) => {
        if (error === null) return resolve({ code: 0, stdout, stderr })
        if (error.killed) {
          return reject(new Error(`timed out after ${options.timeoutMs / 1000} seconds`))
        }
        if (typeof error.code === 'number') return resolve({ code: error.code, stdout, stderr })
        reject(error)
      },
    )
    child.stdin?.end()
  })
}

export function parseClaudeUsage(json: string, now: Date): UsageReading {
  let output: unknown
  try {
    output = JSON.parse(json)
  } catch {
    return unavailable('claude /usage did not print JSON')
  }
  const { result, is_error: isError } = (output ?? {}) as { result?: unknown; is_error?: unknown }
  if (typeof result !== 'string') return unavailable('claude /usage printed no result')
  const lines = result.split(/\r?\n/)
  const firstLine = lines.map((line) => line.trim()).find((line) => line !== '')
  if (isError === true) return unavailable(firstLine ?? 'claude /usage reported an error')

  const windows: UsageWindow[] = []
  for (const line of lines) {
    const match = WINDOW_LINE.exec(line)
    if (!match) continue
    const [, name = '', percent = '', reset = '', zone = ''] = match
    windows.push({
      name,
      percent: Number(percent),
      resetsAt: resetTime(reset, zone, now),
      decides: DECIDING.has(name),
    })
  }
  if (windows.length === 0) return unavailable(firstLine ?? 'claude /usage printed no limits')
  return {
    harness: 'Claude',
    kind: 'limit',
    windows,
    spend: null,
    observedAt: now.toISOString(),
    state: 'ok',
    reason: null,
  }
}

function unavailable(reason: string): UsageReading {
  return {
    harness: 'Claude',
    kind: 'limit',
    windows: [],
    spend: null,
    observedAt: null,
    state: 'unavailable',
    reason,
  }
}

// `Nov 28 at 5:59pm`, `Nov 28 at 5pm` or a bare `5:59pm`, read in the named zone, as an ISO time in
// UTC. A date takes the nearest year that puts it after `now`; a bare time is today or tomorrow,
// whichever is the nearer one after `now`. Null when the text or the zone cannot be read.
export function resetTime(text: string, zone: string, now: Date): string | null {
  const match = RESET_TEXT.exec(text)
  if (!match) return null
  const [, monthName, dayText, hourText, minuteText, meridiem] = match
  const hour12 = Number(hourText)
  const minute = minuteText === undefined ? 0 : Number(minuteText)
  if (hour12 < 1 || hour12 > 12 || minute > 59) return null
  const hour = (hour12 % 12) + (meridiem === 'pm' ? 12 : 0)

  let format: Intl.DateTimeFormat
  try {
    format = wallClock(zone)
  } catch {
    return null
  }
  const today = wallTime(format, now.getTime())
  const candidates: Array<[number, number, number]> = []
  if (monthName === undefined) {
    const tomorrow = new Date(Date.UTC(today.year, today.month - 1, today.day + 1))
    candidates.push([today.year, today.month, today.day])
    candidates.push([tomorrow.getUTCFullYear(), tomorrow.getUTCMonth() + 1, tomorrow.getUTCDate()])
  } else {
    const month = MONTHS.indexOf(monthName) + 1
    if (month === 0) return null
    candidates.push([today.year, month, Number(dayText)])
    candidates.push([today.year + 1, month, Number(dayText)])
  }
  for (const [year, month, day] of candidates) {
    const at = zonedToUtc(format, year, month, day, hour, minute)
    if (at !== null && at > now.getTime()) return new Date(at).toISOString()
  }
  return null
}

interface Wall {
  year: number
  month: number
  day: number
  hour: number
  minute: number
  second: number
}

function wallClock(zone: string): Intl.DateTimeFormat {
  return new Intl.DateTimeFormat('en-US', {
    timeZone: zone,
    hourCycle: 'h23',
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
    hour: 'numeric',
    minute: 'numeric',
    second: 'numeric',
  })
}

function wallTime(format: Intl.DateTimeFormat, ms: number): Wall {
  const parts = Object.fromEntries(
    format.formatToParts(new Date(ms)).map((part) => [part.type, Number(part.value)]),
  )
  // formatToParts gives every field asked for; NaN for a missing one makes the time invalid.
  const part = (type: string): number => parts[type] ?? Number.NaN
  return {
    year: part('year'),
    month: part('month'),
    day: part('day'),
    hour: part('hour') % 24,
    minute: part('minute'),
    second: part('second'),
  }
}

// The milliseconds since 1970 of a wall-clock time in the zone of `format`; null for a date that
// does not exist, such as Feb 30.
function zonedToUtc(
  format: Intl.DateTimeFormat,
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
): number | null {
  const wall = Date.UTC(year, month - 1, day, hour, minute)
  const asDate = new Date(wall)
  if (asDate.getUTCMonth() !== month - 1 || asDate.getUTCDate() !== day) return null
  const offset = (ms: number): number => {
    const w = wallTime(format, ms)
    return Date.UTC(w.year, w.month - 1, w.day, w.hour, w.minute, w.second) - ms
  }
  const guess = wall - offset(wall)
  return wall - offset(guess)
}
