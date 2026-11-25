import { describe, expect, it } from 'vitest'
import { createLoginLimiter } from './gateway-login-limiter.ts'

describe('bounded private login rate limiter', () => {
  it('blocks attempts beyond the configured allowance', () => {
    const limiter = createLoginLimiter({ maxAttempts: 2, windowMs: 1000 })
    expect(limiter.allow('peer-a')).toBe(true)
    expect(limiter.allow('peer-a')).toBe(true)
    expect(limiter.allow('peer-a')).toBe(false)
    expect(limiter.allow('peer-b')).toBe(true)
  })

  it('resets a peer after the time window expires', () => {
    let clock = 100
    const limiter = createLoginLimiter({ maxAttempts: 1, windowMs: 1000, now: () => clock })
    expect(limiter.allow('peer-a')).toBe(true)
    clock = 1099
    expect(limiter.allow('peer-a')).toBe(false)
    clock = 1100
    expect(limiter.allow('peer-a')).toBe(true)
  })

  it('bounds aggregate admissions even when rotating peers evict records', () => {
    let clock = 0
    const limiter = createLoginLimiter({
      maxAttempts: 2,
      windowMs: 1000,
      maxPeers: 2,
      now: () => clock,
    })
    for (let index = 0; index < 30; index += 1) {
      expect(limiter.allow(`peer-${index}`)).toBe(true)
    }
    expect(limiter.allow('peer-0')).toBe(false)
    expect(limiter.allow('new-peer')).toBe(false)
    clock = 1000
    expect(limiter.allow('new-peer')).toBe(true)
  })

  it('does not replenish the global budget at a fixed window boundary', () => {
    let clock = 0
    const limiter = createLoginLimiter({ maxAttempts: 2, windowMs: 1000, now: () => clock })
    clock = 999
    for (let index = 0; index < 30; index += 1) {
      expect(limiter.allow(`peer-${index}`)).toBe(true)
    }
    clock = 1000
    expect(limiter.allow('new-peer')).toBe(false)
    clock = 1999
    expect(limiter.allow('new-peer')).toBe(true)
  })

  it('refuses invalid limits', () => {
    expect(() => createLoginLimiter({ maxAttempts: 0, windowMs: 100 })).toThrow()
    expect(() => createLoginLimiter({ maxAttempts: 1, windowMs: 0 })).toThrow()
    expect(() => createLoginLimiter({ maxAttempts: 1, windowMs: 100, maxPeers: 0 })).toThrow()
  })
})
