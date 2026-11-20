// Short-lived opaque browser sessions for the *future* private PWA gateway.
// The localhost Node/Tauri hosts never use this module.
//
// This is an in-memory foundation for tests and a single gateway process. It is
// NOT a durable or multi-replica production session store: a gateway restart
// invalidates every session. Login and HTTP cookie delivery are not implemented.
import { createHash, randomBytes } from 'node:crypto'
import type { IncomingMessage } from 'node:http'
import type { GatewaySession } from './gateway.ts'

export const SESSION_COOKIE = 'synapse_session'

interface RecordEntry {
  readonly session: GatewaySession
  readonly expiresAt: number
}

export interface SessionStoreOptions {
  readonly now?: () => number
  readonly ttlMs?: number
  readonly maxSessions?: number
  readonly maxSessionsPerUser?: number
}

export interface IssuedSession {
  readonly token: string
  readonly session: GatewaySession
  readonly expiresAt: number
}

function digest(token: string): string {
  return createHash('sha256').update(token).digest('hex')
}

// Reject duplicate, malformed and ambiguous cookies rather than selecting an
// arbitrary value. Browser cookies are untrusted input.
export function sessionTokenFromCookie(header: string | undefined): string | null {
  if (header === undefined || header.length > 4096) return null
  let token: string | null = null
  for (const entry of header.split(';')) {
    const part = entry.trim()
    const equals = part.indexOf('=')
    if (equals < 0) continue
    if (part.slice(0, equals) !== SESSION_COOKIE) continue
    if (token !== null) return null
    const candidate = part.slice(equals + 1)
    if (!/^[A-Za-z0-9_-]{43}$/.test(candidate)) return null
    token = candidate
  }
  return token
}

export function sessionCookie(token: string): string {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error('invalid session token')
  return `${SESSION_COOKIE}=${token}; Path=/; HttpOnly; Secure; SameSite=Strict`
}

export function clearSessionCookie(): string {
  return `${SESSION_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0`
}

export function createGatewaySessions(options: SessionStoreOptions = {}) {
  const now = options.now ?? Date.now
  const ttlMs = options.ttlMs ?? 8 * 60 * 60 * 1000
  const maxSessions = options.maxSessions ?? 32
  const maxSessionsPerUser = options.maxSessionsPerUser ?? 8
  if (
    !Number.isSafeInteger(ttlMs) ||
    ttlMs <= 0 ||
    !Number.isSafeInteger(maxSessions) ||
    maxSessions <= 0 ||
    !Number.isSafeInteger(maxSessionsPerUser) ||
    maxSessionsPerUser <= 0
  ) {
    throw new Error('invalid gateway session limits')
  }
  const sessions = new Map<string, RecordEntry>()

  function purgeExpired(): void {
    const time = now()
    for (const [key, entry] of sessions) {
      if (entry.expiresAt <= time) sessions.delete(key)
    }
  }

  function resolve(token: string): RecordEntry | null {
    const entry = sessions.get(digest(token))
    if (!entry) return null
    if (entry.expiresAt <= now()) {
      sessions.delete(digest(token))
      return null
    }
    return entry
  }

  return {
    issue(userId: string): IssuedSession {
      if (!userId.trim()) throw new Error('user ID required')
      purgeExpired()
      // Drop the oldest session belonging to this user once at the per-user
      // limit. Invalidation is visible to the WebSocket recheck callback.
      const owned = [...sessions.entries()].filter(([, entry]) => entry.session.userId === userId)
      if (owned.length >= maxSessionsPerUser) {
        const oldest = owned[0]
        if (oldest) sessions.delete(oldest[0])
      }
      // Preserve space for other users: never evict their sessions.
      if (sessions.size >= maxSessions) {
        const oldestOwn = [...sessions.entries()].find(
          ([, entry]) => entry.session.userId === userId,
        )
        if (!oldestOwn) throw new Error('gateway session limit reached')
        sessions.delete(oldestOwn[0])
      }
      const token = randomBytes(32).toString('base64url')
      const session = { userId, sessionId: randomBytes(16).toString('hex') }
      const expiresAt = now() + ttlMs
      sessions.set(digest(token), { session, expiresAt })
      return { token, session, expiresAt }
    },
    authenticate(request: IncomingMessage): Promise<GatewaySession | null> {
      const header = request.headers.cookie
      const token = sessionTokenFromCookie(header)
      return Promise.resolve(token === null ? null : (resolve(token)?.session ?? null))
    },
    sessionValid(session: GatewaySession): Promise<boolean> {
      purgeExpired()
      for (const entry of sessions.values()) {
        if (
          entry.session.sessionId === session.sessionId &&
          entry.session.userId === session.userId
        )
          return Promise.resolve(true)
      }
      return Promise.resolve(false)
    },
    revoke(token: string): void {
      sessions.delete(digest(token))
    },
    revokeUser(userId: string): void {
      for (const [key, entry] of sessions) {
        if (entry.session.userId === userId) sessions.delete(key)
      }
    },
  }
}
