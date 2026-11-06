import { describe, expect, it } from 'vitest'
import { checkRequest, type Policy, type RequestFacts } from './guards.ts'

const policy: Policy = {
  allowedHosts: new Set(['127.0.0.1:5174']),
  allowedOrigins: new Set(['http://localhost:5173']),
  token: 'secret-token',
}

const good: RequestFacts = {
  host: '127.0.0.1:5174',
  origin: 'http://localhost:5173',
  token: 'secret-token',
  contentType: 'application/json',
}

describe('checkRequest', () => {
  it('lets a request from the app through', () => {
    expect(checkRequest(good, policy)).toBeNull()
  })

  it('lets a request with no Origin through when it has the token', () => {
    expect(checkRequest({ ...good, origin: undefined }, policy)).toBeNull()
  })

  it('refuses another Host, as a DNS-rebinding page would send', () => {
    expect(checkRequest({ ...good, host: 'evil.example:5174' }, policy)?.status).toBe(403)
  })

  it('refuses another Origin', () => {
    expect(checkRequest({ ...good, origin: 'https://evil.example' }, policy)?.status).toBe(403)
  })

  it('refuses a missing or a wrong token', () => {
    expect(checkRequest({ ...good, token: undefined }, policy)?.status).toBe(401)
    expect(checkRequest({ ...good, token: 'secret-tokeN' }, policy)?.status).toBe(401)
    expect(checkRequest({ ...good, token: 'short' }, policy)?.status).toBe(401)
  })

  it('refuses a content type a page can send without a preflight', () => {
    expect(checkRequest({ ...good, contentType: 'text/plain' }, policy)?.status).toBe(415)
    expect(checkRequest({ ...good, contentType: undefined }, policy)?.status).toBe(415)
  })
})
