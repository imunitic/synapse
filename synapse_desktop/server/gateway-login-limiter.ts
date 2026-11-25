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
  // Aggregate admissions remain bounded even when peer records are evicted.
  const maxGlobalAttempts = 30
  let globalStart = now()
  let globalCount = 0
  return {
    allow(peer: string): boolean {
      const time = now()
      if (time - globalStart >= windowMs) {
        globalStart = time
        globalCount = 0
      }
      if (globalCount >= maxGlobalAttempts) return false
      let entry = peers.get(peer)
      if (entry && time - entry.start >= windowMs) {
        peers.delete(peer)
        entry = undefined
      }
      if (!entry) {
        if (peers.size >= maxPeers) {
          const oldest = peers.keys().next().value
          if (oldest !== undefined) peers.delete(oldest)
        }
        globalCount += 1
        peers.set(peer, { start: time, count: 1 })
        return true
      }
      if (entry.count >= maxAttempts) return false
      globalCount += 1
      entry.count += 1
      return true
    },
  }
}
