import { describe, expect, it } from 'vitest'
import { formatDuration, formatStartTime, timeAgo } from './format.ts'

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

describe('timeAgo', () => {
  const now = new Date('2026-11-08T12:00:00Z')

  it('says how long ago in the largest whole unit', () => {
    expect(timeAgo('2026-11-08T11:59:30Z', now)).toBe('just now')
    expect(timeAgo('2026-11-08T11:59:00Z', now)).toBe('1 minute ago')
    expect(timeAgo('2026-11-08T11:15:00Z', now)).toBe('45 minutes ago')
    expect(timeAgo('2026-11-08T10:00:00Z', now)).toBe('2 hours ago')
    expect(timeAgo('2026-11-07T11:00:00Z', now)).toBe('1 day ago')
    expect(timeAgo('2026-11-01T12:00:00Z', now)).toBe('7 days ago')
  })

  it('gives the date for what is over a month old, and nothing for what is not a time', () => {
    expect(timeAgo('2026-09-01T12:00:00Z', now)).toBe('2026-09-01')
    expect(timeAgo('yesterday', now)).toBe('')
  })

  it('does not say a time in the future is before now', () => {
    expect(timeAgo('2026-11-09T12:00:00Z', now)).toBe('just now')
  })
})

describe('formatStartTime', () => {
  it('writes the day, month and time in local time', () => {
    // A time with no zone is read as local time, so the test holds in any zone.
    expect(formatStartTime('2026-11-26T12:59:00')).toBe('26 Nov 12:59')
    expect(formatStartTime('2026-01-05T08:03:00')).toBe('5 Jan 08:03')
  })

  it('gives nothing for what is not a time', () => {
    expect(formatStartTime('yesterday')).toBe('')
  })
})
