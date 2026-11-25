import { afterEach, describe, expect, it } from 'vitest'
import type { UsageEvent, UsageReading } from '../shared/usage.ts'
import { createUsage, type Usage } from './usage.ts'

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

async function until(done: () => boolean, ms = 2000): Promise<void> {
  const end = Date.now() + ms
  while (!done()) {
    if (Date.now() > end) throw new Error('timed out')
    await sleep(5)
  }
}

const claudeOk = (percent: number): UsageReading => ({
  harness: 'Claude',
  kind: 'limit',
  windows: [{ name: 'Current session', percent, resetsAt: null, decides: true }],
  spend: null,
  observedAt: '2026-11-25T10:00:00.000Z',
  state: 'ok',
  reason: null,
})

const failed = (state: UsageReading['state'], reason: string): UsageReading => ({
  harness: 'Claude',
  kind: 'limit',
  windows: [],
  spend: null,
  observedAt: null,
  state,
  reason,
})

// A provider that counts its reads and answers from `answers`, the last one again once they run out.
function provider(answers: UsageReading[], delayMs = 0) {
  const fake = {
    reads: 0,
    read: async (): Promise<UsageReading> => {
      const answer = answers[Math.min(fake.reads, answers.length - 1)]
      if (answer === undefined) throw new Error('a provider needs at least one answer')
      fake.reads += 1
      if (delayMs > 0) await sleep(delayMs)
      return answer
    },
  }
  return fake
}

const stops: (() => void)[] = []
afterEach(() => {
  for (const stop of stops.splice(0)) stop()
})

function watch(usage: Usage): UsageEvent[] {
  const seen: UsageEvent[] = []
  stops.push(usage.subscribe((event) => seen.push(event)))
  return seen
}

describe('the usage of the harnesses', () => {
  it('reads nothing while no client is subscribed', async () => {
    const fake = provider([claudeOk(10)])
    createUsage({ providers: [fake.read], intervalMs: 20 })
    await sleep(80)
    expect(fake.reads).toBe(0)
  })

  it('gives a subscriber an event at once, and a later one the last event without a read', async () => {
    const fake = provider([claudeOk(10)])
    const usage = createUsage({ providers: [fake.read], intervalMs: 10_000 })
    const first = watch(usage)
    await until(() => first.length === 1)
    expect(first[0]).toEqual({ readings: [claudeOk(10)] })
    const second = watch(usage)
    expect(second).toEqual([{ readings: [claudeOk(10)] }])
    expect(fake.reads).toBe(1)
  })

  it('reads all providers in parallel, in their order', async () => {
    const slow = provider([claudeOk(10)], 40)
    const quick = provider([failed('not-installed', 'codex is not on PATH')])
    const usage = createUsage({ providers: [slow.read, quick.read], intervalMs: 10_000 })
    const seen = watch(usage)
    await until(() => seen.length === 1)
    expect(seen[0]?.readings.map((r) => r.state)).toEqual(['ok', 'not-installed'])
  })

  it('reads again at the interval', async () => {
    const fake = provider([claudeOk(10), claudeOk(20), claudeOk(30)])
    const usage = createUsage({ providers: [fake.read], intervalMs: 30 })
    const seen = watch(usage)
    await until(() => seen.length >= 3)
    expect(seen[2]?.readings[0]?.windows[0]?.percent).toBe(30)
  })

  it('stops reading when the last client unsubscribes', async () => {
    const fake = provider([claudeOk(10)])
    const usage = createUsage({ providers: [fake.read], intervalMs: 20 })
    const stop = usage.subscribe(() => undefined)
    await until(() => fake.reads >= 2)
    stop()
    const reads = fake.reads
    await sleep(80)
    expect(fake.reads).toBe(reads)
  })

  it('keeps the old figures as stale when an ok provider later fails', async () => {
    const fake = provider([claudeOk(29), failed('unavailable', 'claude /usage: timed out')])
    const usage = createUsage({ providers: [fake.read], intervalMs: 30 })
    const seen = watch(usage)
    await until(() => seen.length >= 2)
    expect(seen[1]?.readings[0]).toEqual({
      ...claudeOk(29),
      state: 'stale',
      reason: 'claude /usage: timed out',
    })
  })

  it('drops the old figures after a sign-out, so a later failure has none', async () => {
    const fake = provider([
      claudeOk(29),
      failed('not-signed-in', 'not signed in'),
      failed('unavailable', 'claude /usage: timed out'),
    ])
    const usage = createUsage({ providers: [fake.read], intervalMs: 30 })
    const seen = watch(usage)
    await until(() => seen.length >= 3)
    expect(seen[2]?.readings[0]).toEqual(failed('unavailable', 'claude /usage: timed out'))
  })

  it('starts one read for two nudges 10 ms apart', async () => {
    const fake = provider([claudeOk(10)], 30)
    const usage = createUsage({ providers: [fake.read], intervalMs: 10_000, nudgeQuietMs: 0 })
    const seen = watch(usage)
    await until(() => seen.length === 1)
    usage.nudge()
    await sleep(10)
    usage.nudge()
    await until(() => seen.length === 2)
    await sleep(60)
    expect(fake.reads).toBe(2)
  })

  it('does not read on a nudge within the quiet time after a read', async () => {
    const fake = provider([claudeOk(10)])
    const usage = createUsage({ providers: [fake.read], intervalMs: 10_000, nudgeQuietMs: 10_000 })
    const seen = watch(usage)
    await until(() => seen.length === 1)
    usage.nudge()
    await sleep(30)
    expect(fake.reads).toBe(1)
  })
})
