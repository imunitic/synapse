// How much of Codex's rate limits is used, asked of `codex app-server` over its JSON-RPC on stdio:
// one message per line, without the `"jsonrpc": "2.0"` field the app-server neither sends nor
// expects. The mapper reads only the fields of `shared/examples/_usage-codex.json`, which follows
// the app-server's `account/rateLimits/read` response. The Rust host reads it alike in
// `src-tauri/src/usage_codex.rs`, and both are tested on the same fixture.

import { spawn } from 'node:child_process'
import type { EventEmitter } from 'node:events'
import type { Readable, Writable } from 'node:stream'
import type { UsageReading, UsageWindow } from '../shared/usage.ts'

export const CODEX_USAGE_ARGS = ['app-server']
export const CODEX_USAGE_TIMEOUT_MS = 20_000

// The parts of a started `codex app-server` that a read uses; a test hands in streams of its own.
export interface CodexChild extends EventEmitter {
  stdin: Writable | null
  stdout: Readable | null
  kill: () => void
}

export interface CodexUsageDeps {
  findProgram: (name: string) => Promise<string | null>
  spawn: (program: string, args: string[]) => CodexChild
  clientVersion: string
  now: () => Date
}

// Codex's rate limits, read now. No process is started when `codex` is not on PATH, and the one
// started is killed once it has answered, failed or taken longer than 20 seconds.
export async function readCodexUsage(deps: CodexUsageDeps): Promise<UsageReading> {
  const program = await deps.findProgram('codex')
  if (program === null) return failed('not-installed', 'codex is not on PATH')
  let child: CodexChild
  try {
    child = deps.spawn(program, CODEX_USAGE_ARGS)
  } catch (error) {
    return failed('unavailable', `codex app-server: ${message(error)}`)
  }
  const { stdin, stdout } = child
  if (stdin === null || stdout === null) {
    child.kill()
    return failed('unavailable', 'codex app-server: no stdio')
  }
  const send = (value: object): void => {
    stdin.write(`${JSON.stringify(value)}\n`)
  }

  return new Promise<UsageReading>((resolve) => {
    let done = false
    let buffered = ''
    const finish = (reading: UsageReading): void => {
      if (done) return
      done = true
      clearTimeout(timer)
      stdout.off('data', onData)
      child.kill()
      resolve(reading)
    }
    const timer = setTimeout(
      () =>
        finish(
          failed(
            'unavailable',
            `codex app-server: timed out after ${CODEX_USAGE_TIMEOUT_MS / 1000} seconds`,
          ),
        ),
      CODEX_USAGE_TIMEOUT_MS,
    )
    const onData = (chunk: Buffer | string): void => {
      buffered += chunk.toString()
      let newline = buffered.indexOf('\n')
      while (newline !== -1 && !done) {
        const line = buffered.slice(0, newline).trim()
        buffered = buffered.slice(newline + 1)
        newline = buffered.indexOf('\n')
        if (line !== '') onLine(line)
      }
    }
    const onLine = (line: string): void => {
      let reply: { id?: unknown; result?: unknown; error?: { message?: unknown } }
      try {
        reply = JSON.parse(line)
      } catch {
        return
      }
      if (reply.id !== 1 && reply.id !== 2) return
      if (reply.error !== undefined) {
        finish(codexError(String(reply.error?.message ?? 'codex app-server reported an error')))
      } else if (reply.id === 1) {
        send({ method: 'initialized' })
        send({ method: 'account/rateLimits/read', id: 2 })
      } else {
        finish(mapCodexRateLimits(reply.result, deps.now()))
      }
    }
    stdout.on('data', onData)
    stdout.once('end', () =>
      finish(failed('unavailable', 'codex app-server: exited before answering')),
    )
    child.once('error', (error) =>
      finish(failed('unavailable', `codex app-server: ${message(error)}`)),
    )
    stdin.on('error', () => {})
    send({
      method: 'initialize',
      id: 1,
      params: { clientInfo: { name: 'synapse-desktop', version: deps.clientVersion } },
    })
  })
}

// Starts `codex app-server` with piped stdio, its stderr ignored.
export function spawnCodex(program: string, args: string[]): CodexChild {
  return spawn(program, args, { stdio: ['pipe', 'pipe', 'ignore'] })
}

// The response to `account/rateLimits/read` as windows: `rateLimits.primary` and
// `rateLimits.secondary`, each present one named from its duration.
export function mapCodexRateLimits(result: unknown, now: Date): UsageReading {
  const rateLimits = field(result, 'rateLimits')
  if (rateLimits === null || typeof rateLimits !== 'object') {
    return failed('unavailable', 'codex gave no rateLimits')
  }
  const windows: UsageWindow[] = []
  for (const slot of ['primary', 'secondary']) {
    const window = field(rateLimits, slot)
    if (window === null || window === undefined) continue
    const usedPercent = field(window, 'usedPercent')
    if (typeof usedPercent !== 'number' || usedPercent < 0) {
      return failed('unavailable', `codex gave no usedPercent for its ${slot} limit`)
    }
    const minutes = field(window, 'windowDurationMins')
    const resetsAt = field(window, 'resetsAt')
    windows.push({
      name: typeof minutes === 'number' ? windowName(minutes) : slot,
      percent: usedPercent,
      resetsAt: typeof resetsAt === 'number' ? new Date(resetsAt * 1000).toISOString() : null,
      decides: true,
    })
  }
  if (windows.length === 0) return failed('unavailable', 'codex gave no rate limit windows')
  return {
    harness: 'Codex',
    kind: 'limit',
    windows,
    spend: null,
    observedAt: now.toISOString(),
    state: 'ok',
    reason: null,
  }
}

// `5h` for 300 minutes, `weekly` for 10080, whole hours under 48 hours and whole days from there.
export function windowName(minutes: number): string {
  if (minutes === 300) return '5h'
  if (minutes === 10080) return 'weekly'
  if (minutes < 48 * 60) return `${Math.round(minutes / 60)}h`
  return `${Math.round(minutes / (24 * 60))}d`
}

// An error reply: one about logging in or auth means Codex is not signed in.
function codexError(text: string): UsageReading {
  return /login|log in|auth/i.test(text)
    ? failed('not-signed-in', text)
    : failed('unavailable', text)
}

function field(value: unknown, key: string): unknown {
  return value !== null && typeof value === 'object'
    ? (value as Record<string, unknown>)[key]
    : undefined
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function failed(state: UsageReading['state'], reason: string): UsageReading {
  return {
    harness: 'Codex',
    kind: 'limit',
    windows: [],
    spend: null,
    observedAt: null,
    state,
    reason,
  }
}
