import type { IncomingMessage } from 'node:http'
import { describe, expect, it } from 'vitest'
import {
  clearSessionCookie,
  createGatewaySessions,
  sessionCookie,
  sessionTokenFromCookie,
  SESSION_COOKIE,
} from './gateway-sessions.ts'

function request(cookie?: string): IncomingMessage {
  return { headers: cookie === undefined ? {} : { cookie } } as IncomingMessage
}

describe('private gateway sessions', () => {
  it('issues opaque tokens and authenticates only the session owner', async () => {
    const store = createGatewaySessions()
    const issued = store.issue('alice')
    expect(issued.token).toMatch(/^[A-Za-z0-9_-]{43}$/)
    expect(issued.token).not.toContain('alice')
    expect(await store.authenticate(request(`${SESSION_COOKIE}=${issued.token}`))).toEqual(
      issued.session,
    )
    expect(await store.sessionValid(issued.session)).toBe(true)
    expect(await store.authenticate(request())).toBeNull()
    expect(await store.authenticate(request(`${SESSION_COOKIE}=${'a'.repeat(43)}`))).toBeNull()
  })

  it('expires at the configured deadline and invalidates active WebSocket sessions', async () => {
    let time = 1000
    const store = createGatewaySessions({ now: () => time, ttlMs: 500 })
    const issued = store.issue('alice')
    time = 1499
    expect(await store.sessionValid(issued.session)).toBe(true)
    time = 1500
    expect(await store.authenticate(request(`${SESSION_COOKIE}=${issued.token}`))).toBeNull()
    expect(await store.sessionValid(issued.session)).toBe(false)
  })

  it('revokes a single session or all sessions belonging to a user', async () => {
    const store = createGatewaySessions()
    const first = store.issue('alice')
    const second = store.issue('alice')
    const other = store.issue('bob')
    store.revoke(first.token)
    expect(await store.sessionValid(first.session)).toBe(false)
    expect(await store.sessionValid(second.session)).toBe(true)
    store.revokeUser('alice')
    expect(await store.sessionValid(second.session)).toBe(false)
    expect(await store.sessionValid(other.session)).toBe(true)
  })

  it('refuses ambiguous cookies and invalid token formats', () => {
    const token = 'a'.repeat(43)
    expect(sessionTokenFromCookie(`${SESSION_COOKIE}=${token}`)).toBe(token)
    expect(sessionTokenFromCookie(`foo=1; ${SESSION_COOKIE}=${token}`)).toBe(token)
    expect(
      sessionTokenFromCookie(`${SESSION_COOKIE}=${token}; ${SESSION_COOKIE}=${token}`),
    ).toBeNull()
    expect(sessionTokenFromCookie(`${SESSION_COOKIE}=${token}%0a`)).toBeNull()
    expect(sessionTokenFromCookie(`${SESSION_COOKIE}=${token}; ${'x'.repeat(4096)}`)).toBeNull()
    expect(sessionTokenFromCookie(undefined)).toBeNull()
  })

  it('sets restrictive cookies and clears them with matching attributes', () => {
    const token = 'b'.repeat(43)
    expect(sessionCookie(token)).toContain('HttpOnly; Secure; SameSite=Strict')
    expect(sessionCookie(token)).toContain('Path=/')
    expect(clearSessionCookie()).toContain('Max-Age=0')
    expect(clearSessionCookie()).toContain('Path=/; HttpOnly; Secure; SameSite=Strict')
    expect(() => sessionCookie('bad')).toThrow()
  })

  it('bounds active sessions, then admits new sessions after expiration', () => {
    let time = 0
    const store = createGatewaySessions({ now: () => time, ttlMs: 100, maxSessions: 1 })
    store.issue('alice')
    expect(() => store.issue('bob')).toThrow(/limit reached/)
    time = 100
    expect(() => store.issue('bob')).not.toThrow()
  })

  it('evicts the oldest session for the same user and invalidates its open-socket identity', async () => {
    const store = createGatewaySessions({ maxSessions: 3, maxSessionsPerUser: 2 })
    const first = store.issue('alice')
    const second = store.issue('alice')
    const bob = store.issue('bob')
    const third = store.issue('alice')
    expect(await store.sessionValid(first.session)).toBe(false)
    expect(await store.authenticate(request(`${SESSION_COOKIE}=${first.token}`))).toBeNull()
    expect(await store.sessionValid(second.session)).toBe(true)
    expect(await store.sessionValid(third.session)).toBe(true)
    expect(await store.sessionValid(bob.session)).toBe(true)
  })

  it('rejects missing user identity and invalid store limits', () => {
    const store = createGatewaySessions()
    expect(() => store.issue('')).toThrow()
    expect(() => createGatewaySessions({ ttlMs: 0 })).toThrow()
    expect(() => createGatewaySessions({ maxSessions: 0 })).toThrow()
  })
})
