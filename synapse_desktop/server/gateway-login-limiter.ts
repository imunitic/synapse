// Bounded, in-memory limiter for the private gateway login endpoint.
// Keys must come from the trusted TCP peer, never client-supplied proxy headers.
export interface LoginLimiterOptions {
  readonly maxAttempts: number
  readonly windowMs: number
  readonly maxPeers?: number
  readonly now?: () => number
}

export function createLoginLimiter(options: LoginLimiterOptions) {
  const { maxAttempts, windowMs } = options
  const maxPeers = options.maxPeers ?? 1024
  const now = options.now ?? Date.now
  if (
    !Number.isSafeInteger(maxAttempts) ||
    maxAttempts < 1 ||
    !Number.isSafeInteger(windowMs) ||
    windowMs < 1 ||
    !Number.isSafeInteger(maxPeers) ||
    maxPeers < 1
  ) {
    throw new Error('invalid login rate limits')
  }

  const peers = new Map<string, { start: number; count: number }>()
  return {
    allow(peer: string): boolean {
      const time = now()
      let entry = peers.get(peer)
      if (entry && time - entry.start >= windowMs) {
        peers.delete(peer)
        entry = undefined
      }
      if (!entry) {
        // Retire old records first, but never evict active entries simply to
        // admit new peer identities. Saturation fails closed.
        if (peers.size >= maxPeers) {
          for (const [key, value] of peers) {
            if (time - value.start >= windowMs) peers.delete(key)
          }
          if (peers.size >= maxPeers) return false
        }
        peers.set(peer, { start: time, count: 1 })
        return true
      }
      if (entry.count >= maxAttempts) return false
      entry.count += 1
      return true
    },
  }
}
