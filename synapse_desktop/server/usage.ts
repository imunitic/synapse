// The usage of the harnesses, read every 5 minutes while a client watches and published on the
// `usage` topic. Nothing is read while no client is subscribed. A provider that read well once and
// then fails keeps its figures, marked `stale`. The Rust host does the same in
// `src-tauri/src/usage.rs`.

import type { UsageEvent, UsageReading } from '../shared/usage.ts'
import { loadConfig } from './config-store.ts'
import type { Environment } from './roots.ts'
import { findExecutable } from './inject.ts'
import { readClaudeUsage, runProgram } from './usage-claude.ts'
import { readCodexUsage, spawnCodex } from './usage-codex.ts'
import { readOpencodeUsage } from './usage-opencode.ts'

export const USAGE_INTERVAL_MS = 300_000
export const USAGE_NUDGE_QUIET_MS = 30_000

export interface UsageOptions {
  providers: Array<() => Promise<UsageReading>> // Claude, Codex, Opencode, in that order
  intervalMs?: number // default 300_000
  nudgeQuietMs?: number // default 30_000
}

export interface Usage {
  subscribe(push: (event: UsageEvent) => void): () => void
  // Reads now, unless a read is running or the last one finished under `nudgeQuietMs` ago.
  nudge(): void
}

export function createUsage(options: UsageOptions): Usage {
  const intervalMs = options.intervalMs ?? USAGE_INTERVAL_MS
  const nudgeQuietMs = options.nudgeQuietMs ?? USAGE_NUDGE_QUIET_MS
  const { providers } = options
  const subscribers = new Set<(event: UsageEvent) => void>()
  // The last reading of each provider that was `ok`, kept for when a later read fails.
  const good: (UsageReading | null)[] = providers.map(() => null)
  let last: UsageEvent | null = null
  let finishedAt = Number.NEGATIVE_INFINITY
  let reading = false
  let timer: NodeJS.Timeout | undefined

  const settled = (reading: UsageReading, index: number): UsageReading => {
    if (reading.state === 'ok') {
      good[index] = reading
      return reading
    }
    // A sign-out or an uninstall makes the kept figures meaningless.
    if (reading.state === 'not-signed-in' || reading.state === 'not-installed') good[index] = null
    const kept = good[index]
    if (reading.state !== 'unavailable' || kept == null) return reading
    return { ...kept, state: 'stale', reason: reading.reason }
  }

  async function read(): Promise<void> {
    if (reading) return
    reading = true
    try {
      const readings = await Promise.all(
        providers.map((provider, index) =>
          provider().then(
            (result) => settled(result, index),
            () => null,
          ),
        ),
      )
      last = { readings: readings.filter((r): r is UsageReading => r !== null) }
      finishedAt = Date.now()
      for (const push of [...subscribers]) push(last)
    } finally {
      reading = false
    }
  }

  return {
    subscribe(push) {
      subscribers.add(push)
      if (last !== null) push(last)
      if (Date.now() - finishedAt >= intervalMs) void read()
      if (timer === undefined) timer = setInterval(() => void read(), intervalMs)
      return () => {
        subscribers.delete(push)
        if (subscribers.size === 0 && timer !== undefined) {
          clearInterval(timer)
          timer = undefined
        }
      }
    },
    nudge() {
      if (subscribers.size === 0 || reading) return
      if (Date.now() - finishedAt < nudgeQuietMs) return
      void read()
    },
  }
}

// The three providers as they read this machine: programs on the host's PATH, run in the work
// directory, or the home folder when none is set.
export function systemProviders(
  environment: Environment,
  configFile: string,
): UsageOptions['providers'] {
  const findProgram = (name: string) => findExecutable(name, environment.env.PATH ?? '')
  const workDir = async () => {
    try {
      const { workDir } = await loadConfig(configFile, environment)
      return workDir ?? environment.home
    } catch {
      return environment.home
    }
  }
  const now = () => new Date()
  return [
    () => readClaudeUsage({ findProgram, run: runProgram, workDir, now }),
    () =>
      readCodexUsage({
        findProgram,
        spawn: spawnCodex,
        clientVersion: process.env.npm_package_version ?? '0.0.0',
        now,
      }),
    () => readOpencodeUsage({ findProgram, run: runProgram, workDir, now }),
  ]
}
