// How much of each harness's limit is used, or what it has cost today, as a host reads it and
// publishes it on the `usage` topic. The Rust host has the same shape in `src-tauri/src/usage.rs`.

import { z } from 'zod'
import { harnessSchema } from './calls.ts'

// `ok`: read just now. `stale`: the last good figures, kept after a read failed. The other three
// say why there is no figure at all.
export const usageStateSchema = z.enum([
  'ok',
  'stale',
  'not-signed-in',
  'unavailable',
  'not-installed',
])

// One limit of a harness: a session, a week, the 5 hours of Codex.
export const usageWindowSchema = z.object({
  // 'Current session', 'Current week (all models)', '5h', 'weekly'
  name: z.string(),
  percent: z.number().nonnegative(),
  // ISO 8601 UTC, null when the text gave none.
  resetsAt: z.string().nullable(),
  // Counts toward the bar item's colour and figure.
  decides: z.boolean(),
})

export const usageReadingSchema = z.object({
  harness: harnessSchema,
  kind: z.enum(['limit', 'spend']),
  // Empty for spend.
  windows: z.array(usageWindowSchema),
  spend: z
    .object({ amount: z.number().nonnegative(), period: z.enum(['today', 'session']) })
    .nullable(),
  // When the figures were read; null when never read.
  observedAt: z.string().nullable(),
  state: usageStateSchema,
  // In words, for any state but ok.
  reason: z.string().nullable(),
})

export const usageEventSchema = z.object({ readings: z.array(usageReadingSchema) })

export type UsageState = z.infer<typeof usageStateSchema>
export type UsageWindow = z.infer<typeof usageWindowSchema>
export type UsageReading = z.infer<typeof usageReadingSchema>
export type UsageEvent = z.infer<typeof usageEventSchema>
