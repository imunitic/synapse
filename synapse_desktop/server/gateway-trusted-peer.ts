// Resolve the rate-limit identity from an explicitly configured trusted proxy.
// The reverse proxy must replace (not append) forwarded client address headers.
// Never trust a forwarding header received directly from an untrusted TCP peer.
import type { IncomingMessage } from 'node:http'
import { isIP } from 'node:net'

function canonicalIp(address: string): string {
  // Node's dual-stack listeners report IPv4 peers in IPv6-mapped form.
  const unwrapped = /^::ffff:/i.test(address) ? address.slice(7) : address
  return isIP(unwrapped) === 4 ? unwrapped : address.toLowerCase()
}

export function createTrustedPeerKey(trustedProxyAddresses: readonly string[]) {
  if (trustedProxyAddresses.some((address) => isIP(address) === 0)) {
    throw new Error('invalid trusted proxy address')
  }
  const trusted = new Set(trustedProxyAddresses.map(canonicalIp))
  return (request: IncomingMessage): string | null => {
    const peer = request.socket.remoteAddress
    if (!peer) return null
    const normalizedPeer = canonicalIp(peer)
    if (!trusted.has(normalizedPeer)) return normalizedPeer
    const forwarded = request.headers['x-forwarded-for']
    // Only a single canonical IP is accepted. The trusted proxy must strip
    // inbound forwarding headers and replace with its verified client IP.
    if (typeof forwarded !== 'string' || forwarded.includes(',') || isIP(forwarded) === 0) {
      return null
    }
    return forwarded
  }
}
