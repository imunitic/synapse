/// <reference types="vite/client" />
import { describe, expect, it } from 'vitest'
import { topicSchema } from './protocol.ts'
import { usageEventSchema } from './usage.ts'

const example = Object.values(
  import.meta.glob<unknown>('./examples/_usage-event.json', { eager: true, import: 'default' }),
)[0]

describe('the usage of the harnesses', () => {
  it('accepts the example event', () => {
    expect(example).toBeDefined()
    expect(usageEventSchema.safeParse(example).success).toBe(true)
  })

  it('is published on the topic usage, and nothing under it is a topic', () => {
    expect(topicSchema.safeParse('usage').success).toBe(true)
    expect(topicSchema.safeParse('usage.x').success).toBe(false)
  })
})
