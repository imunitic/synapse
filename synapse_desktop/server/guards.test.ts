import { describe, expect, it } from 'vitest'
import { checkUpgrade, type Policy, type RequestFacts } from './guards.ts'

const policy: Policy = {
  allowedHosts: new Set(['127.0.0.1:5174']),
  allowedOrigins: new Set(['http://localhost:5173']),
  token: 'secret-token',
}

const good: RequestFacts = {
  host: '127.0.0.1:5174',
  origin: 'http://localhost:5173',
  token: 'secret-token',
}

describe('checkUpgrade', () => {
  it('lets a request from the app through', () => {
    expect(checkUpgrade(good, policy)).toBeNull()
  })

  it('lets a request with no Origin through when it has the token', () => {
    expect(checkUpgrade({ ...good, origin: undefined }, policy)).toBeNull()
  })

  it('refuses another Host, as a DNS-rebinding page would send', () => {
    expect(checkUpgrade({ ...good, host: 'evil.example:5174' }, policy)?.status).toBe(403)
  })

  it('refuses another Origin', () => {
    expect(checkUpgrade({ ...good, origin: 'https://evil.example' }, policy)?.status).toBe(403)
  })

  it('refuses a missing or a wrong token', () => {
    expect(checkUpgrade({ ...good, token: undefined }, policy)?.status).toBe(401)
    expect(checkUpgrade({ ...good, token: 'secret-tokeN' }, policy)?.status).toBe(401)
    expect(checkUpgrade({ ...good, token: 'short' }, policy)?.status).toBe(401)
  })
})
