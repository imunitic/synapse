// Resolve the rate-limit identity from an explicitly configured trusted proxy.
// The reverse proxy must replace (not append) forwarded client address headers.
// Never trust a forwarding header received directly from an untrusted TCP peer.
import type { IncomingMessage } from 'node:http'
import { isIP } from 'node:net'

function canonicalIp(address: string): string {
  if (isIP(address) === 4) return address
  const normalized = new URL(`http://[${address.split('%')[0]}]/`).hostname.slice(1, -1)
  const mapped = /^::ffff:([0-9a-f]+):([0-9a-f]+)$/.exec(normalized)
  if (!mapped) return normalized
  const high = Number.parseInt(mapped[1] ?? '', 16)
  const low = Number.parseInt(mapped[2] ?? '', 16)
  return [high >> 8, high & 255, low >> 8, low & 255].join('.')
}

function rateLimitKey(address: string): string {
  const ip = canonicalIp(address)
  if (isIP(ip) === 4) return ip
  const [left = '', right = ''] = ip.split('::')
  const prefix = left ? left.split(':') : []
  const suffix = right ? right.split(':') : []
  const zeros = Array<string>(8 - prefix.length - suffix.length).fill('0')
  const groups = [...prefix, ...zeros, ...suffix]
  return groups.slice(0, 4).join(':') + '::/64'
}

export function createTrustedPeerKey(trustedProxyAddresses: readonly string[]) {
  if (trustedProxyAddresses.some((address) => isIP(address) === 0)) {
    throw new Error('invalid trusted proxy address')
  }
  const trusted = new Set(trustedProxyAddresses.map(canonicalIp))
  return (request: IncomingMessage): string | null => {
    const peer = request.socket.remoteAddress
    if (!peer || isIP(peer) === 0) return null
    const normalizedPeer = canonicalIp(peer)
    if (!trusted.has(normalizedPeer)) return rateLimitKey(normalizedPeer)
    const forwarded = request.headers['x-forwarded-for']
    // Only a single canonical IP is accepted. The trusted proxy must strip
    // inbound forwarding headers and replace with its verified client IP.
    if (typeof forwarded !== 'string' || forwarded.includes(',') || isIP(forwarded) === 0) {
      return null
    }
    return rateLimitKey(forwarded)
  }
}
