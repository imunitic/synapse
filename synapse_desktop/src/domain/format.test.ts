import { describe, expect, it } from 'vitest'
import { formatDuration } from './format.ts'

describe('formatDuration', () => {
  it('writes hours, minutes and seconds, leaving out what is zero', () => {
    expect(formatDuration(1800)).toBe('30m')
    expect(formatDuration(90)).toBe('1m 30s')
    expect(formatDuration(3600)).toBe('1h')
    expect(formatDuration(3661)).toBe('1h 1m 1s')
    expect(formatDuration(45)).toBe('45s')
  })

  it('writes zero and anything below it as 0s', () => {
    expect(formatDuration(0)).toBe('0s')
    expect(formatDuration(-5)).toBe('0s')
  })
})
