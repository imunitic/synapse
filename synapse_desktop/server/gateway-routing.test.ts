import { describe, expect, it } from 'vitest'
import { hostForPrincipal, RouteDenied, type PrivateHost } from './gateway-routing.ts'

const first: PrivateHost = { userId: 'person-a', backend: 'http://synapse-a:5174' }
const second: PrivateHost = { userId: 'person-b', backend: 'http://synapse-b:5174' }
const hosts = new Map([
  [first.userId, first],
  [second.userId, second],
])

describe('authenticated gateway host routing', () => {
  it('maps each authenticated principal only to their configured host', () => {
    expect(hostForPrincipal({ userId: 'person-a' }, hosts)).toBe(first)
    expect(hostForPrincipal({ userId: 'person-b' }, hosts)).toBe(second)
  })

  it('rejects unauthenticated and empty principals', () => {
    expect(() => hostForPrincipal(null, hosts)).toThrow(RouteDenied)
    expect(() => hostForPrincipal({ userId: '' }, hosts)).toThrow(RouteDenied)
  })

  it('rejects unknown principals instead of routing to a default host', () => {
    expect(() => hostForPrincipal({ userId: 'person-c' }, hosts)).toThrow(RouteDenied)
  })

  it('rejects a configured route whose declared owner mismatches the session owner', () => {
    const invalid = new Map([['person-a', second]])
    expect(() => hostForPrincipal({ userId: 'person-a' }, invalid)).toThrow(RouteDenied)
  })
})
