// Any web page the user visits can send a request to a localhost server, so
// every request has to prove it comes from this app's own page.

import { timingSafeEqual } from 'node:crypto'

export interface RequestFacts {
  host: string | undefined
  origin: string | undefined
  token: string | undefined
  contentType: string | undefined
}

export interface Policy {
  allowedHosts: ReadonlySet<string>
  allowedOrigins: ReadonlySet<string>
  token: string
}

export interface Refusal {
  status: number
  error: string
}

function sameToken(given: string, expected: string): boolean {
  const a = Buffer.from(given)
  const b = Buffer.from(expected)
  return a.length === b.length && timingSafeEqual(a, b)
}

// Null when the request may go on. A request with no Origin does not come from
// a page; it still needs the token.
export function checkRequest(facts: RequestFacts, policy: Policy): Refusal | null {
  if (facts.host === undefined || !policy.allowedHosts.has(facts.host)) {
    return { status: 403, error: 'host not allowed' }
  }
  if (facts.origin !== undefined && !policy.allowedOrigins.has(facts.origin)) {
    return { status: 403, error: 'origin not allowed' }
  }
  if (facts.token === undefined || !sameToken(facts.token, policy.token)) {
    return { status: 401, error: 'missing or wrong token' }
  }
  // A page can send text/plain without a preflight; JSON it cannot.
  if (!facts.contentType?.toLowerCase().startsWith('application/json')) {
    return { status: 415, error: 'content type must be application/json' }
  }
  return null
}
