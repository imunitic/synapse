// Resolve the rate-limit identity from an explicitly configured trusted proxy.
// The reverse proxy must replace (not append) forwarded client address headers.
// Never trust a forwarding header received directly from an untrusted TCP peer.
import type { IncomingMessage } from 'node:http'
import { isIP } from 'node:net'

export function createTrustedPeerKey(trustedProxyAddresses: readonly string[]) {
  if (trustedProxyAddresses.some((address) => isIP(address) === 0)) {
    throw new Error('invalid trusted proxy address')
  }
  const trusted = new Set(trustedProxyAddresses)
  return (request: IncomingMessage): string | null => {
    const peer = request.socket.remoteAddress
    if (!peer) return null
    if (!trusted.has(peer)) return peer
    const forwarded = request.headers['x-forwarded-for']
    // Only a single canonical IP is accepted. The trusted proxy must strip
    // inbound forwarding headers and replace with its verified client IP.
    if (typeof forwarded !== 'string' || forwarded.includes(',') || isIP(forwarded) === 0) {
      return null
    }
    return forwarded
  }
}
